/*******************************************************************************

    Entry point for the faucet tool

    The tool currently contains a basic version of a transaction generator.

    Copyright:
        Copyright (c) 2020 BOS Platform Foundation Korea
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module faucet.main;

import agora.api.FullNode;
import agora.common.Amount;
import agora.common.crypto.Key;
import agora.common.Serializer;
import agora.common.Types;
import agora.consensus.data.genesis.Test;
import agora.consensus.data.Transaction;
import agora.consensus.state.UTXOSet;
import agora.utils.Test;

import std.algorithm;
import std.random;
import std.range;
import std.stdio;

import core.time;

import vibe.core.core;
import vibe.core.log;
import vibe.web.rest;


/// Configuration parameter for Faucet
private struct Config
{
    /// How frequently we run our periodic task
    static immutable interval = 15.seconds;

    /// Between how many addresses we split a transaction by
    static immutable count = 15;
}

/// Holds the state of our application and contains update methods
private struct State
{
    /// The UTXO set at `this.known`
    private TestUTXOSet utxos;
    /// The most up-to-date block we know about
    private Height known;

    /// Update the UTXO set and the `known` height
    private bool update (API client, Height from) @safe
    {
        const height = client.getBlockHeight();
        if (from >= height + 1)
        {
            if (from > height + 1)
                logError("Agora reported a Height of %s but we are at %s", height, this.known);
            return false;
        }

        const blocks = client.getBlocksFrom(from, cast(uint) (height - from + 1));
        logInfo("Updating state: blocks [%s .. %s] (%s)", from, height, blocks.length);
        const current_len = this.utxos.storage.length;

        foreach (ref b; blocks)
            foreach (ref tx; b.txs)
                if (tx.type == TxType.Payment)
                    this.utxos.updateUTXOCache(tx, b.header.height);

        // Use signed arithmetic to avoid negative values wrapping around
        const long delta = (cast(long) this.utxos.storage.length) - current_len;
        logInfo("UTXO delta: %s", delta);
        this.known = blocks[$ - 1].header.height;

        return true;
    }
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

    return utxo_rng
        .map!(tup => TxBuilder(tup.value.output, tup.key))
        .map!(txb => txb.split(
                  WK.Keys.byRange()
                  .drop(uniform(0, 1378 - count, rndGen))
                  .take(count)
                  .map!(k => k.address))
              .sign()
            );
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

private auto mergeTx (UR) (UR utxo_rng) @safe
{
    static assert (isInputRange!UR);

    return utxo_rng
            .filter!(tup => tup.value.output.value > Amount(Config.count))
            .map!(tup => TxBuilder(tup.value.output, tup.key)
            .sign());
}

/*******************************************************************************

    Perform state setup and make sure there is enough UTXOs for us to use

    Populate the `state` variable with the current state of node using `client`,
    and create transactions that will spread all spendable transactions from
    the last known block to `count` addresses.

    Params:
      state = The application state
      client = An API instance to connect to a node
      count = The number of keys to spread the transactions to

*******************************************************************************/

public void setup (ref State state, API client, uint count)
{
    state.update(client, Height(0));
    const utxo_len = state.utxos.storage.length;
    immutable size_t WKKeysCount = 1378;

    logInfo("Setting up: height=%s, %s UTXOs found", state.known, utxo_len);
    if (utxo_len < 200)
    {
        assert(utxo_len >= 8);
        state.utxos.storage.byKeyValue().take(8).splitTx(25)
            .each!(tx => client.putTransaction(tx));
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
      state =  The current state of Faucet

*******************************************************************************/

void send (API client, ref State state)
{
    state.update(client, Height(state.known + 1));
    if (state.known < 1)
        return logInfo("Waiting for setup to be completed");

    logInfo("About to send transactions...");

    // Sort them so we don't iterate multiple time
    // Note: This may cause a lot of memory usage, might need restructuing later
    // Mutable because of https://issues.dlang.org/show_bug.cgi?id=9792
    auto sutxo = state.utxos.values.sort!((a, b) => a.output.value < b.output.value);
    const size = sutxo.length();
    logInfo("\tUTXO set: %d entries", size);

    immutable median = sutxo[size / 2].output.value;
    // Should be 500M (5,000,000,000,000,000) for the time being
    immutable sum = sutxo.map!(utxo => utxo.output.value)
        .fold!((a, b) => Amount(a).mustAdd(b))(Amount(0));
    auto mean = Amount(sum); mean.div(size);

    logInfo("\tMedian: %s, Avg: %s", median, mean);
    logInfo("\tL: %s, H: %s", sutxo[0].output.value, sutxo[$-1].output.value);

    if (state.utxos.storage.length > 200)
    {
        foreach (tx; state.utxos.byKeyValue().take(16).mergeTx())
        {
            client.putTransaction(tx);
            logInfo("Transaction sent: %s", tx);
        }
    }
    else
    {
        foreach (tx; state.utxos.byKeyValue().take(16).splitTx(Config.count))
        {
            client.putTransaction(tx);
            logInfo("Transaction sent: %s", tx);
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

    try
    {
        logInfo("The address of node is %s", args[1]);
        auto node = new RestInterfaceClient!API(args[1]);
        State state;
        state.utxos = new TestUTXOSet();
        state.setup(node, Config.count);
        setTimer(Config.interval, () => send(node, state), true);
        return runEventLoop();
    }
    catch (Exception e)
    {
        logError("Exception while connecting: %s", e);
        printHelp();
        return 1;
    }
}
