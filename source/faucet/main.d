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
import agora.common.crypto.Key;
import agora.common.Serializer;
import agora.common.Types;
import agora.consensus.data.genesis.Test;
import agora.consensus.data.Transaction;
import agora.consensus.data.UTXOSetValue;
import agora.consensus.UTXOSet;
import agora.utils.Test;

import std.algorithm;
import std.random;
import std.range;
import std.stdio;

import core.time;

import vibe.core.core;
import vibe.core.log;
import vibe.web.rest;

/// How frequently we run our periodic task
immutable interval = 15.seconds;
/// How many transactions we send per task run
immutable count = 15;

/// Holds the state of our application and contains update methods
private struct State
{
    /// The UTXO set at `this.known`
    private TestUTXOSet utxos;
    /// The most up-to-date block we know about
    private Height known;

    /// Update the UTXO set and the `known` height
    private bool update (API client, Height from)
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
                    this.utxos.put(tx);

        // Use signed arithmetic to avoid negative values wrapping around
        const long delta = (cast(long) this.utxos.storage.length) - current_len;
        logInfo("UTXO delta: %s", delta);
        this.known = blocks[$ - 1].header.height;

        return true;
    }
}

/*******************************************************************************

    Perform state setup and make sure there is enough UTXOs for us to use

    Populate the `state` variable with the current state of node using `client`,
    and create transactions the will spread all spendable transactions from
    the last known block to `count` addresses.

    Params:
      state = The application state
      client = An API instance to connect to a node
      count = The number of keys to spread the transactions to

    Returns:
      The generated transactions

*******************************************************************************/

public Transaction[] setup (ref State state, API client, uint count)
{
    state.update(client, Height(0));
    const utxo_len = state.utxos.storage.length;
    immutable size_t WKKeysCount = 1378;

    // If there are less than 50 UTXOs, then print the current UTXO set.
    // This number is arbitrary for the time being.
    if (utxo_len < 50)
        foreach (key, utxo; state.utxos)
            logInfo("UTXO: [%s] %s", key, utxo);

    auto last_block = client.getBlocksFrom(state.known, 1);
    assert(last_block.length == 1 && last_block[0].header.height == state.known);

    auto txs = last_block[0].spendable().map!(txb => txb.split(
                    WK.Keys.byRange().drop(uniform(0, WKKeysCount - count, rndGen))
                    .take(count).map!(k => k.address)).sign()).array();

    return txs;
}

/*******************************************************************************

    A task called periodically that generates and send transactions to a node

    This function first sends the previously generated set of transactions,
    using `initial_txs` on its first run, then generate a new set based on
    what it just sent, and will send them on the next run.

    Params:
      client = An API instance to connect to a node
      utxo = The current UTXO set
      initial_txs = The initial set of transactions to send on the first run

*******************************************************************************/

void send (API client, TestUTXOSet utxo, Transaction[] initial_txs) @safe
{
    static Transaction[] txs;
    if (!txs.length)
        txs = initial_txs;

    foreach (tx; txs)
    {
        client.putTransaction(tx);
        logInfo("Transaction sent: %s", tx);
    }

    txs = txs.map!(txb => TxBuilder(txb).split(
             WK.Keys.byRange().drop(uniform(0, 1378 - count, rndGen))
             .take(count).map!(k => k.address))
             .sign()).array();
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
        auto txs = state.setup(node, count);
        setTimer(interval, () => send(node, state.utxos, txs), true);
        return runEventLoop();
    }
    catch (Exception e)
    {
        logError("Exception while connecting: %s", e);
        printHelp();
        return 1;
    }
}
