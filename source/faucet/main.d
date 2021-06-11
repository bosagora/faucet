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
import faucet.config;
import faucet.stats;

import agora.api.FullNode;
import agora.common.Amount;
import agora.common.Types;
import agora.consensus.data.genesis.Test;
import agora.consensus.data.Transaction;
import agora.consensus.state.UTXOSet;
import agora.crypto.Key;
import agora.serialization.Serializer;
import agora.stats.Server;
import agora.stats.Utils;
import agora.utils.Test;
import agora.script.Lock;

import std.algorithm;
import std.exception;
import std.file;
import std.format;
import std.getopt;
import std.random;
import std.range;
import std.stdio;
import std.typecons;

import core.time;

import vibe.core.core;
import vibe.core.log;
import vibe.http.fileserver;
import vibe.http.router;
import vibe.http.server;
import vibe.inet.url;
import vibe.web.rest;

/// The keys that will be used for generating transactions
private SecretKey[PublicKey] secret_keys;

/// The configuration for faucet as a faucet and a tx generator
private Config config;

/// Override the symbol 'TxBuilder' and use the Config as a default
public struct Builder
{
    /// Underlying instance
    TxBuilder builder;

    /// Forward methods
    alias builder this;

    /// Forward to the underlying TxBuilder constructor
    public this (in PublicKey refundMe) @safe pure nothrow
    {
        this.builder = TxBuilder(refundMe);
    }

    /// Ditto
    public this (in Lock lock) @safe pure nothrow
    {
        this.builder = TxBuilder(lock);
    }

    /// Ditto
    public this (const Transaction tx) @safe nothrow
    {
        this.builder = TxBuilder(tx);
    }

    /// Ditto
    public this (const Transaction tx, uint index) @safe nothrow
    {
        this.builder = TxBuilder(tx, index);
    }

    /// Ditto
    public this (const Transaction tx, uint index, in Lock lock) @safe nothrow
    {
        this.builder = TxBuilder(tx, index, lock);
    }

    /// Ditto
    public this (in Output utxo, in Hash hash) @safe nothrow
    {
        this.builder = TxBuilder(utxo, hash);
    }

    /// Forward to `TxBuilder.sign` with a different default unlocker
    public Transaction sign (in OutputType type = OutputType.Payment, ubyte[] data = null,
        Height lock_height = Height(0), uint unlock_age = 0) @safe nothrow
    {
        return this.builder.sign(type, data, lock_height, unlock_age, &this.keyUnlocker);
    }

    ///
    private Unlock keyUnlocker (in Transaction tx, in OutputRef out_ref) @safe nothrow
    {
        auto ownerSecret = secret_keys[out_ref.output.address];
        assert(ownerSecret !is SecretKey.init,
                "Address not known: " ~ out_ref.output.address.toString());

        return genKeyUnlock(KeyPair.fromSeed(ownerSecret).sign(tx));
    }
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
                   .filter!(tup => tup.value.output.address in secret_keys)
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
                        if (tx.isPayment)
                            this.utxos.updateUTXOCache(tx, b.header.height, PublicKey.init);

                // Use signed arithmetic to avoid negative values wrapping around
                const long delta = (cast(long) this.utxos.storage.length) - current_len;
                logInfo("UTXO delta: %s", delta);
                this.known = blocks[$ - 1].header.height;
                from += blocks.length;
            } while (this.known < height);

            this.owned_utxos = this.getOwnedUTXOs();
            assert(this.owned_utxos.length);

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
    private API[] clients;

    /// Timer on which transactions are generated and send
    public Timer sendTx;

    /// Listener for the user interface, if any
    public HTTPListener webInterface;

    /***************************************************************************

        Stats-related fields

        Those fields are used to expose internal statistics about the faucet on
        an HTTP interface that is ultimately queried by a Prometheus server.

    ***************************************************************************/

    /// Ditto
    protected StatsServer stats_server;

    /// Ditto
    protected FaucetStats faucet_stats;

    /// Ditto
    mixin DefineCollectorForStats!("faucet_stats", "collectStats");

    /***************************************************************************

        Constructor

        Params:
          config = Config instance
          address = The address (IPv4, IPv6, hostname) of the node

    ***************************************************************************/

    public this ()
    {
        // Create client for each address
        config.tx_generator.addresses.each!(address =>
            this.clients ~= new RestInterfaceClient!API(address));
        this.state.utxos = new TestUTXOSet();
        Utils.getCollectorRegistry().addCollector(&this.collectStats);
    }

    /*******************************************************************************

        Take one of the clients selecting it randomly

        Returns:
          A client to send transactions or requests

    *******************************************************************************/

    private API randomClient () @trusted
    {
        return choice(this.clients);
    }

    /*******************************************************************************

        Splits the Outputs from `utxo_rng` towards `count` random keys

        The keys are continuous in an associative array.
        We take `count` keys starting at a random position
        (no less than `count` before the end).

        Params:
          UR = Range of tuple with an `Output` (`value`) and
                 a `Hash` (`key`), as its first and second element, respectively
          count = The number of keys up to the number of available keys
            to spread the UTXOs to which will wrap around the keys if required

        Returns:
          A range of Transactions

    *******************************************************************************/

    private auto splitTx (UR) (UR utxo_rng, uint count)
    {
        static assert (isInputRange!UR);

        return utxo_rng
            .filter!(tup => tup.value.output.value >= Amount(count))
            .map!(tup => Builder(tup.value.output, tup.key))
            .map!(txb => txb.split(
                    secret_keys.byKey() // AA keys are addresses
                    .cycle()    // cycle the range of keys as needed
                    .drop(uniform(0, count, rndGen))    // start at some random position
                    .take(count))
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

        return Builder(secret_keys.byKey() // AA keys are addresses
            .drop(uniform(0, secret_keys.length, rndGen)).front())
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
        while (!this.state.update(randomClient(), Height(0)))
            sleep(5.seconds);

        const utxo_len = this.state.utxos.storage.length;

        logInfo("Setting up: height=%s, %s UTXOs found", this.state.known, utxo_len);
        if (utxo_len < 200)
        {
            assert(utxo_len >= 8);
            this.splitTx(this.state.utxos.storage.byKeyValue(), 100)
                .take(8)
                .each!(tx => this.randomClient().putTransaction(tx));
            this.faucet_stats.increaseMetricBy!"faucet_transactions_sent_total"(8);
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
        if (this.state.utxos.storage.length == 0)
            this.setup(config.tx_generator.split_count);

        // For now we always send to first client
        if (this.state.update(randomClient(), Height(this.state.known + 1)))
            logTrace("State has been updated: %s", this.state.known);

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

        if (this.state.utxos.storage.length > config.tx_generator.merge_threshold)
        {
            auto tx = this.mergeTx(this.state.utxos.byKeyValue().take(uniform(10, 100, rndGen)));
            this.randomClient().putTransaction(tx);
            logDebug("Transaction sent: %s", tx);
            this.faucet_stats.increaseMetricBy!"faucet_transactions_sent_total"(1);
        }
        else
        {
            auto rng = this.splitTx(this.state.utxos.byKeyValue(), config.tx_generator.split_count)
                .take(uniform(1, 10, rndGen));
            foreach (tx; rng)
            {
                this.randomClient().putTransaction(tx);
                logDebug("Transaction sent: %s", tx);
                this.faucet_stats.increaseMetricBy!"faucet_transactions_sent_total"(1);
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
        Amount leftover = amount.coins;
        auto owned_utxo_rng = this.state.owned_utxos.byKeyValue()
            // do not pick already used UTXOs
            .filter!(pair => pair.key !in this.used_utxos);
        auto first_utxo = owned_utxo_rng.front;
        // add used UTXO to to used_utxos
        this.used_utxos[first_utxo.key] = first_utxo.value;
        owned_utxo_rng.popFront();
        assert(first_utxo.value.output.value > Amount(0));

        Builder txb = Builder(first_utxo.value.output, first_utxo.key);

        if (leftover <= first_utxo.value.output.value)
        {
            Transaction tx = txb.draw(leftover, [pubkey]).sign();
            logInfo("Sending %s BOA to %s", amount.coins, recv);
            this.randomClient().putTransaction(tx);
            this.faucet_stats.increaseMetricBy!"faucet_transactions_sent_total"(1);
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
            logInfo("Sending %s BOA to %s", amount.coins, recv);
            this.randomClient().putTransaction(tx);
            this.faucet_stats.increaseMetricBy!"faucet_transactions_sent_total"(1);
        }
    }
}

/// Application entry point
int main (string[] args)
{
    string bind;
    bool verbose;
    string configPath = "config.yaml";

    auto helpInfos = getopt(
        args,
        "bind", &bind,
        "c|config", &configPath,
        "stats-port", &config.tx_generator.stats_port,
        "v|verbose", &verbose,
    );

    if (helpInfos.helpWanted)
    {
        defaultGetoptPrinter(
            "Usage: ./faucet <address>, e.g. ./faucet 'http://127.0.0.1:2826'",
            helpInfos.options);
        return 0;
    }

    static void printHelp ()
    {
        stderr.writeln("Usage: ./faucet [-c <path>]");
        stderr.writeln("By default, faucet will attempt to read its configuration from
                        config.yaml");
    }

    if (bind.length) try
    {
        auto bindurl = URL(bind);
        config.web.address = bindurl.host;
        config.web.port = bindurl.port;
    }
    catch (Exception exc)
    {
        stderr.writeln("Could not parse '", bind, "' as a valid URL");
        stderr.writeln("Make sure the address contains a scheme, e.g. 'http://127.0.0.1:2766'");
        return 1;
    }

    // We need proper shut down or Faucet get stuck, see bosagora/faucet#72
    disableDefaultSignalHandlers();
    version (Posix)
    {
        import core.sys.posix.signal;

        sigset_t sigset;
        sigemptyset(&sigset);

        sigaction_t siginfo;
        siginfo.sa_handler = getSignalHandler();
        siginfo.sa_mask = sigset;
        siginfo.sa_flags = SA_RESTART;
        sigaction(SIGINT, &siginfo, null);
        sigaction(SIGTERM, &siginfo, null);
    }

    logInfo("Loading Configuration from %s", configPath);
    config = parseConfigFile(configPath);
    config.tx_generator.seeds.keys.map!(k =>
        KeyPair.fromSeed(SecretKey.fromString(k)))
            .each!(kp => secret_keys.require(kp.address, kp.secret));
    logInfo("%s", config);

    if (bind.length) try
    {
        auto bindurl = URL(bind);
        string address = bindurl.host;
        uint port = bindurl.port;
    }
    catch (Exception exc)
    {
        stderr.writeln("Could not parse '", bind, "' as a valid URL");
        stderr.writeln("Make sure the address contains a scheme, e.g. 'http://127.0.0.1:2766'");
        return 1;
    }

    logInfo("We'll be sending transactions to the following clients: %s", config.tx_generator.addresses);
    inst = new Faucet();
    inst.stats_server = new StatsServer(config.tx_generator.stats_port);

    setLogLevel(verbose ? LogLevel.trace : LogLevel.info);

    inst.sendTx = setTimer(config.tx_generator.send_interval.seconds, () => inst.send(), true);
    inst.webInterface = bind.length ? startListeningInterface(config, inst) : HTTPListener.init;
    return runEventLoop();
}

private HTTPListener startListeningInterface (in Config config, Faucet faucet)
{
    auto settings = new HTTPServerSettings(config.web.address);
    settings.port = config.web.port;
    auto router = new URLRouter();
    router.registerRestInterface(faucet);

    string path = getStaticFilePath();
    /// Convenience redirect, as users expect that accessing '/' redirect to index.html
    router.match(HTTPMethod.GET, "/", staticRedirect("/index.html", HTTPStatus.movedPermanently));
    /// By default, match the underlying files
    router.match(HTTPMethod.GET, "*", serveStaticFiles(path));

    logInfo("About to listen to HTTP: %s:%d", config.web.address, config.web.port);
    return listenHTTP(settings, router);
}

/// Returns: The path at which the files are located
private string getStaticFilePath ()
{
    if (std.file.exists("frontend/index.html"))
        return std.file.getcwd() ~ "/frontend/";

    throw new Exception("Files not found. " ~
                        "This might mean your faucet is not installed correctly. " ~
                        "Searched for `index.html` in '" ~ std.file.getcwd() ~
                        "/frontend/'.");
}

/// Global because we need to access it from our signal handler
private Faucet inst;

/// Type of the handler that is called when a signal is received
private alias SigHandlerT = extern(C) void function (int sig) nothrow;

/// Returns a signal handler
/// This routine is there solely to ensure the function has a mangled name,
/// and doesn't accidentally conflict with other code.
private SigHandlerT getSignalHandler () @safe pure nothrow @nogc
{
    extern(C) void signalHandler (int signal) nothrow
    {
        // Calling `printf` because `writeln` is not `@nogc`
        printf("Received signal %d, shutting down listeners...\n", signal);
        try
        {
            inst.webInterface.stopListening();
            inst.webInterface = typeof(inst.webInterface).init;
            inst.stats_server.shutdown();
            inst.sendTx.stop();
            inst.sendTx = inst.sendTx.init;
            printf("Terminating event loop...\n");
            exitEventLoop();
        }
        catch (Throwable exc)
        {
            printf("Exception thrown while shutting down: %.*s\n",
                   cast(int) exc.msg.length, exc.msg.ptr);
            debug {
                scope (failure) assert(0);
                writeln("========================================");
                writeln("Full stack trace: ", exc);
            }
        }
    }

    return &signalHandler;
}
