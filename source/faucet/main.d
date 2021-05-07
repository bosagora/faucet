/*******************************************************************************

    Entry point for the faucet tool

    The tool currently contains a basic version of a transaction generator.

    Copyright:
        Copyright (c) 2020-2021 BOSAGORA Foundation
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module faucet.main;

import faucet.API;

import agora.api.FullNode;
import agora.common.Amount;
import agora.common.Types;
import agora.consensus.data.genesis.Test;
import agora.consensus.data.Transaction;
import agora.consensus.state.UTXOSet;
import agora.crypto.Key;
import agora.serialization.Serializer;
import agora.utils.Test;

import std.algorithm;
import std.random;
import std.range;
import std.stdio;
import std.typecons;

import core.time;

import vibe.core.core;
import vibe.core.log;
import vibe.http.router;
import vibe.http.server;
import vibe.web.rest;

static immutable KeyCount = WK.Keys.byRange().length;

/// Configuration parameter for Faucet
private struct Config
{
    /// How frequently we run our periodic task
    static immutable interval = 30.seconds;

    /// Between how many addresses we split a transaction by
    static immutable count = 15;

    /// Bind address
    public string address = "0.0.0.0";

    /// Bind port (default: 2766)
    public ushort port = 0xACE;
}

/// Holds the state of our application and contains update methods
private struct State
{
    /// The UTXO set at `this.known`
    private TestUTXOSet utxos;
    /// UTXOs owned by us
    private UTXO[Hash] owned_utxos;
    /// The most up-to-date block we know about
    private Height known;

    /// Get UTXOs owned by us
    private UTXO[Hash] getOwnedUTXOs () nothrow @safe
    {
        return this.utxos.storage.byKeyValue()
                   .filter!(
                       kv => kv.value.output.address == WK.Keys[kv.value.output.address].address)
                   .map!(kv => tuple(kv.key, kv.value))
                   .assocArray();
    }

    /// Update the UTXO set and the `known` height
    private bool update (API client, Height from) @safe
    {
        try
        {
            const height = client.getBlockHeight();
            if (from >= height + 1)
            {
                if (from > height + 1)
                    logError("Agora reported a Height of %s but we are at %s", height, this.known);
                return false;
            }

            do {
                const blocks = client.getBlocksFrom(from, cast(uint) (height - from + 1));
                logInfo("Updating state: blocks [%s .. %s] (%s)", from, height, blocks.length);
                const current_len = this.utxos.storage.length;

                foreach (ref b; blocks)
                    foreach (ref tx; b.txs)
                        if (tx.type == TxType.Payment)
                            this.utxos.updateUTXOCache(tx, b.header.height, PublicKey.init);

                // Use signed arithmetic to avoid negative values wrapping around
                const long delta = (cast(long) this.utxos.storage.length) - current_len;
                logInfo("UTXO delta: %s", delta);
                this.known = blocks[$ - 1].header.height;
                from += blocks.length;
            } while (this.known < height);

            assert(this.getOwnedUTXOs().length);
            this.owned_utxos = this.getOwnedUTXOs();

            return true;
        }
        // The exception that was thrown is likely from the network operation
        // (`getBlockHeight` / `getBlocksFrom`), so just warn and retry later
        catch (Exception e)
        {
            () @trusted { logWarn("Exception thrown while updating state: %s", e.msg); }();
            return false;
        }
    }
}

/*******************************************************************************

    Implementation of the faucet API

    This class implements the business code of the faucet.

*******************************************************************************/

public class Faucet : FaucetAPI
{
    /// Config instance
    private Config config;

    /// The state instance represents the current state of the application.
    /// It is updated in the initial setup, and before a set of transactions
    /// is sent. The update function takes the known height as a parameter,
    /// and determines how many blocks it needs to catch up with. The UTXO set
    /// for a certain height represents the state at that height. Therefore,
    /// `updateUTXOCache` is called for every block until the latest block.
    private State state = State.init;

    /// A storage to keep track of used UTXOs
    private UTXO[Hash] used_utxos;

    /// A client object implementing `API`
    private API client;

    /***************************************************************************

        Constructor

        Params:
          config = Config instance
          address = The address (IPv4, IPv6, hostname) of the node

    ***************************************************************************/

    public this (const Config config, const Address address)
    {
        this.config = config;
        this.client = new RestInterfaceClient!API(address);
        this.state.utxos = new TestUTXOSet();
    }

    /*******************************************************************************

        Splits the Outputs from `utxo_rng` towards `count` random keys

        The keys are continuous in the `WK.Keys.byRange()` range, but the range
        starts at a random position (no less than `count` before the end).

        Params:
          UR = Range of tuple with an `Output` (`value`) and
                 a `Hash` (`key`), as its first and second element, respectively
          count = The number of keys to spread the UTXOs to

        Returns:
          A range of Transactions

    *******************************************************************************/

    private auto splitTx (UR) (UR utxo_rng, uint count)
    {
        static assert (isInputRange!UR);
        assert(count <= KeyCount);

        return utxo_rng
            .filter!(tup => tup.value.output.value >= Amount(count))
            .map!(tup => TxBuilder(tup.value.output, tup.key))
            .map!(txb => txb.split(
                    WK.Keys.byRange()
                    .drop(uniform(0, KeyCount - count, rndGen))
                    .take(count)
                    .map!(k => k.address))
                .sign());
    }

    /*******************************************************************************

        Merges the Outputs from `utxo_rng` into a range of transactions
        with a single input and output.

        Params:
          UR = Range of tuple with an `Output` (`value`) and
          a `Hash` (`key`), as its first and second element, respectively

        Returns:
          A range of Transactions

    *******************************************************************************/

    private Transaction mergeTx (UR) (UR utxo_rng) @safe
    {
        static assert (isInputRange!UR);

        return TxBuilder(WK.Keys[uniform(0, KeyCount, rndGen)].address)
                            .attach(utxo_rng.map!(utxo => utxo.value.output)
                            .zip(utxo_rng.map!(utxo => utxo.key)))
                            .sign();
    }

    /*******************************************************************************

        Perform state setup and make sure there is enough UTXOs for us to use

        Populate the `state` variable with the current state of node using `client`,
        and create transactions that will spread all spendable transactions from
        the last known block to `count` addresses.

        Params:
          client = An API instance to connect to a node
          count = The number of keys to spread the transactions to

    *******************************************************************************/

    public void setup (uint count)
    {
        while (!this.state.update(this.client, Height(0)))
            sleep(5.seconds);

        const utxo_len = this.state.utxos.storage.length;

        logInfo("Setting up: height=%s, %s UTXOs found", this.state.known, utxo_len);
        if (utxo_len < 200)
        {
            assert(utxo_len >= 8);
            this.splitTx(this.state.utxos.storage.byKeyValue().take(8), 100)
                .each!(tx => this.client.putTransaction(tx));
        }
    }

    /*******************************************************************************

        A task called periodically that generates and send transactions to a node

        This function will wait for block 1 to be externalized before doing anything
        (block 1 should be triggered by `setup`).
        Each time this runs, it creates 16 transactions which split an UTXO among
        15 random keys.

        Params:
          client = An API instance to connect to a node

    *******************************************************************************/

    void send ()
    {
        if (!this.state.update(this.client, Height(this.state.known + 1)))
            return;

        if (this.state.known < 1)
            return logInfo("Waiting for setup to be completed");

        logInfo("About to send transactions...");

        // Sort them so we don't iterate multiple time
        // Note: This may cause a lot of memory usage, might need restructuing later
        // Mutable because of https://issues.dlang.org/show_bug.cgi?id=9792
        auto sutxo = this.state.utxos.values.sort!((a, b) => a.output.value < b.output.value);
        const size = sutxo.length();
        logInfo("\tUTXO set: %d entries", size);

        immutable median = sutxo[size / 2].output.value;
        // Should be 500M (5,000,000,000,000,000) for the time being
        immutable sum = sutxo.map!(utxo => utxo.output.value)
            .fold!((a, b) => Amount(a).mustAdd(b))(Amount(0));
        auto mean = Amount(sum); mean.div(size);

        logInfo("\tMedian: %s, Avg: %s", median, mean);
        logInfo("\tL: %s, H: %s", sutxo[0].output.value, sutxo[$-1].output.value);

        if (this.state.utxos.storage.length > 1000)
        {
            auto tx = this.mergeTx(this.state.utxos.byKeyValue().take(uniform(10, 100, rndGen)));
            this.client.putTransaction(tx);
            logDebug("Transaction sent: %s", tx);
        }
        else
        {
            foreach (tx; this.splitTx(this.state.utxos.byKeyValue().take(uniform(1, 10, rndGen)),
                                      this.config.count))
            {
                this.client.putTransaction(tx);
                logDebug("Transaction sent: %s", tx);
            }
        }
    }

    /// GET: /utxos
    public override UTXO[Hash] getUTXOs () pure nothrow @safe
    {
        return this.state.utxos.storage;
    }

    /// POST: /send_transaction
    public override void sendTransaction (string recv, ulong amount)
    {
        PublicKey pubkey = PublicKey.fromString(recv);
        Amount leftover = Amount(amount);
        auto owned_utxo_rng = this.state.owned_utxos.byKeyValue()
            // do not pick already used UTXOs
            .filter!(pair => pair.key !in this.used_utxos);
        auto first_utxo = owned_utxo_rng.front;
        // add used UTXO to to used_utxos
        this.used_utxos[first_utxo.key] = first_utxo.value;
        owned_utxo_rng.popFront();
        assert(first_utxo.value.output.value > Amount(0));

        TxBuilder txb = TxBuilder(first_utxo.value.output, first_utxo.key);

        if (leftover <= first_utxo.value.output.value)
        {
            Transaction tx = txb.draw(leftover, [pubkey]).sign();
            logInfo("Sending %s BOA to %s", amount, recv);
            this.client.putTransaction(tx);
        }
        else
        {
            txb.draw(first_utxo.value.output.value, [pubkey]);
            leftover.sub(first_utxo.value.output.value);

            while (leftover > Amount(0))
            {
                auto new_utxo = owned_utxo_rng.front;
                this.used_utxos[new_utxo.key] = new_utxo.value;
                owned_utxo_rng.popFront();
                assert(new_utxo.value.output.value > Amount(0));

                if (leftover <= new_utxo.value.output.value)
                {
                    txb.attach(new_utxo.value.output, new_utxo.key)
                       .draw(leftover, [pubkey]);
                    break;
                }

                txb.attach(new_utxo.value.output, new_utxo.key)
                   .draw(new_utxo.value.output.value, [pubkey]);
                leftover.sub(new_utxo.value.output.value);
            }

            Transaction tx = txb.sign();
            logInfo("Sending %s BOA to %s", amount, recv);
            this.client.putTransaction(tx);
        }
    }
}

/// Application entry point
int main (string[] args)
{
    static void printHelp ()
    {
        writeln("Usage: ./faucet <address>");
        writeln("Where <address> is a http endpoint, such as 'http://192.168.0.42:8080'");
    }

    if (args.length != 2)
    {
        logInfo("Please enter one value");
        printHelp();
        return 1;
    }

    logInfo("The address of node is %s", args[1]);
    auto faucet = new Faucet(Config.init, args[1]);
    faucet.setup(faucet.config.count);

    setLogLevel(LogLevel.info);
    auto settings = new HTTPServerSettings(faucet.config.address);
    settings.port = faucet.config.port;
    auto router = new URLRouter();
    router.registerRestInterface(faucet);
    logInfo("About to listen to HTTP: %s", settings.port);
    listenHTTP(settings, router);

    setTimer(faucet.config.interval, () => faucet.send(), true);
    return runEventLoop();
}
