/*******************************************************************************

    Configuration for Faucet

    Handle the config settings for both transaction generator and faucet roles

    Copyright:
        Copyright (c) 2020-2021 BOSAGORA Foundation
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module faucet.config;

import dyaml.node;
import dyaml.loader;

import std.exception;
import std.format;

/// Configuration parameter for Faucet
public struct Config
{
    /// configuration for tx generator
    public TxGenerator tx_generator;

    /// config for faucet web
    public Web web;

    this (TxGenerator tx_generator, Web web)
    {
        this.tx_generator = tx_generator;
        this.web = web;
    }
}

///
public struct Seeds
{
    public string[] keys;

    /// We do not want to log the key seeds
    public string toString ()
    {
        return format!"%s keys"(keys.length);
    }
}

///
public struct TxGenerator
{
    /// How frequently we run our periodic task
    public ulong send_interval;

    /// Between how many addresses we split a transaction by
    public uint split_count;

    /// Maximum number of utxo before merging instead of splitting
    public uint merge_threshold;

    /// Addresses to send the transactions to
    public string[] addresses;

    /// Keys from the config
    public Seeds seeds;

    /// Stats port (default: 9113)
    public ushort stats_port;

    ///
    public this (ulong send_interval, uint split_count, uint merge_threshold,
        string[] addresses, Seeds seeds, ushort stats_port = 9113)
    {
        this.send_interval = send_interval;
        this.split_count = split_count;
        this.merge_threshold = merge_threshold;
        this.addresses = addresses;
        this.seeds = seeds;
        this.stats_port = stats_port;
    }

    ///
    public this (Node yaml_node) @safe
    {
        send_interval = yaml_node["send_interval"].as!ulong;
        split_count = yaml_node["split_count"].as!uint;
        merge_threshold = yaml_node["merge_threshold"].as!uint;
        () @trusted { addresses = parseSequence("addresses", yaml_node, true); }();
        () @trusted { seeds.keys = parseSequence("keys", yaml_node, false); }();
        stats_port = yaml_node["stats_port"].as!ushort;
    }
}

/// The Config for the faucet web
public struct Web
{
    /// Address to bind for website
    public string address;

    /// Port to bind for website
    public ushort port;

    ///
    public this (string address, ushort port = 2766)
    {
        this.address = address;
        this.port = port;
    }

    ///
    public this (Node yaml_node) @safe
    {
        this.address = yaml_node["address"].as!string;
        this.port = yaml_node["port"].as!ushort;
    }
}

/// Parse the config file
public Config parseConfigFile (string configPath)
{
    Node root = Loader.fromFile(configPath).load();
    return Config(
        TxGenerator(root["tx_generator"]),
        Web(root["web"]));
}

/// Parse the config section
private string[] parseSequence (string section,
        Node root, bool optional = false)
{
    if (auto yaml_node = section in root)
        enforce(root[section].type == NodeType.sequence,
            format("`%s` section must be a sequence", section));
    else if (optional)
        return null;
    else
        throw new Exception(
            format("The '%s' section is mandatory and must " ~
                "specify at least one item", section));

    string[] result;
    foreach (string item; root[section])
        result ~= item;

    return result;
}
