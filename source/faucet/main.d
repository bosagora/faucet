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
import agora.common.Set;
import agora.common.Types;
import agora.consensus.data.genesis.Test;
import agora.consensus.data.Transaction;
import agora.consensus.state.UTXOSet;
import agora.crypto.Key;
import agora.script.Signature;
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

/// Holds the state of our application and contains update methods
private struct State
{
    /// The UTXO set at `this.known`
    private TestUTXOSet utxos;
    /// UTXOs owned by us
    private UTXO[Hash] owned_utxos;
    /// The most up-to-date block we know about
    private Height known;

    /// A storage to keep track of UTXOs sent in txs
    private Set!Hash sent_utxos;

    /// Get UTXOs owned by us that are spendable
    private UTXO[Hash] getOwnedUTXOs () nothrow @safe
    {
        return this.utxos.storage.byKeyValue()
                   .filter!(tup => tup.value.output.address in secret_keys)
                   .filter!(tup => tup.value.output.type == OutputType.Payment)
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
                        if (!tx.isCoinbase)
                            this.utxos.updateUTXOCache(tx, b.header.height, WK.Keys.CommonsBudget.address);

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

    /// Minimum input value per output
    /// This is to prevent transactions with too little input value to cover the fees.
    private const minInputValuePerOutput = Amount(5_000_000);

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

    ///
    private static Unlock keyUnlocker (in Transaction tx, in OutputRef out_ref) @safe nothrow
    {
        auto ownerSecret = secret_keys[out_ref.output.address];
        assert(ownerSecret !is SecretKey.init,
                "Address not known: " ~ out_ref.output.address.toString());

        return genKeyUnlock(KeyPair.fromSeed(ownerSecret).sign(tx.getChallenge()));
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
            .filter!(tup => tup.value.output.value >= minInputValuePerOutput * count)
            .map!((kv)
            {
                this.state.sent_utxos.put(kv.key);
                return TxBuilder(kv.value.output, kv.key);
            })
            .map!(txb => txb.unlockSigner(&this.keyUnlocker).split(
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

        // AA keys are addresses
        auto builder = TxBuilder(
            secret_keys.byKey().drop(uniform(0, secret_keys.length, rndGen)).front());
        builder.attach(utxo_rng);
        return builder.unlockSigner(&this.keyUnlocker).sign();
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

        const utxo_len = this.state.owned_utxos.length;

        logInfo("Setting up: height=%s, %s UTXOs found", this.state.known, utxo_len);
        if (utxo_len < 200)
        {
            assert(utxo_len >= 1);
            this.splitTx(this.state.owned_utxos.byKeyValue(), count)
                .take(8)
                .each!((tx)
                {
                    this.randomClient().postTransaction(tx);
                    this.faucet_stats.increaseMetricBy!"faucet_transactions_sent_total"(1);
                });
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
        immutable sum = sutxo.map!(utxo => utxo.output.value).sum();
        auto mean = Amount(sum); mean.div(size);

        logInfo("\tMedian: %s, Avg: %s", median, mean);
        logInfo("\tL: %s, H: %s", sutxo[0].output.value, sutxo[$-1].output.value);

        if (this.state.utxos.storage.length > config.tx_generator.merge_threshold)
        {
            auto utxo_rng = this.state.owned_utxos.byKeyValue()
                .filter!(kv => kv.key !in this.state.sent_utxos)
                .filter!(kv => kv.value.output.value >= minInputValuePerOutput)
                .take(uniform(10, 100, rndGen));
            if (utxo_rng.empty)
                logInfo("Waiting for unspent utxo");
            else
            {
                auto tx = this.mergeTx(
                    utxo_rng.map!((kv)
                    {
                        this.state.sent_utxos.put(kv.key);
                        return tuple(kv.value.output, kv.key);
                    }));
                this.randomClient().postTransaction(tx);
                logDebug("Transaction sent (merge): %s", tx);
                this.faucet_stats.increaseMetricBy!"faucet_transactions_sent_total"(1);
            }
        }
        else
        {
            auto rng = this.splitTx(
                    this.state.owned_utxos.byKeyValue()
                        .filter!(kv => kv.key !in this.state.sent_utxos),
                    config.tx_generator.split_count)
                .take(uniform(1, 10, rndGen));
            foreach (tx; rng)
            {
                this.randomClient().postTransaction(tx);
                logDebug("Transaction sent (split): %s", tx);
                this.faucet_stats.increaseMetricBy!"faucet_transactions_sent_total"(1);
            }
        }
    }

    /// GET: /utxos
    public override UTXO[Hash] getUTXOs () pure nothrow @safe
    {
        return this.state.utxos.storage;
    }

    /// POST: /send
    public override void sendTransaction (string recv)
    {
        PublicKey pubkey = PublicKey.fromString(recv);
        ulong amount = 100;
        Amount leftover = amount.coins;
        auto owned_utxo_rng = this.state.owned_utxos.byKeyValue()
            // do not pick already used UTXOs
            .filter!(pair => pair.key !in this.used_utxos);

        auto owned_utxo_len = owned_utxo_rng.take(2).count;
        if (owned_utxo_len <= 1)
        {
            logError("Insufficient UTXOs in storage. # of UTXOs: %s", owned_utxo_len);
            throw new Exception(format("Insufficient UTXOs in storage. # of UTXOs: %s", owned_utxo_len));
        }

        auto first_utxo = owned_utxo_rng.front;
        // add used UTXO to to used_utxos
        this.used_utxos[first_utxo.key] = first_utxo.value;
        owned_utxo_rng.popFront();
        assert(first_utxo.value.output.value > Amount(0));

        TxBuilder txb = TxBuilder(first_utxo.value.output, first_utxo.key);

        if (leftover <= first_utxo.value.output.value)
        {
            Transaction tx = txb.unlockSigner(&this.keyUnlocker)
                .draw(leftover, [pubkey])
                .sign();
            logInfo("Sending %s BOA to %s", amount, recv);
            this.randomClient().postTransaction(tx);
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

            Transaction tx = txb.unlockSigner(&this.keyUnlocker).sign();
            logInfo("Sending %s BOA to %s", amount, recv);
            this.randomClient().postTransaction(tx);
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

    logInfo("We'll be sending transactions to the following clients: %s", config.tx_generator.addresses);
    inst = new Faucet();
    inst.stats_server = new StatsServer(config.tx_generator.stats_port);

    setLogLevel(verbose ? LogLevel.trace : LogLevel.info);

    inst.sendTx = setTimer(config.tx_generator.send_interval.seconds, () => inst.send(), true);
    if (config.web.address.length)
        inst.webInterface = startListeningInterface(config, inst);
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

    if (std.file.exists("/usr/share/faucet/frontend/index.html"))
        return "/usr/share/faucet/frontend/";

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
