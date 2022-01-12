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

import agora.config.Attributes;
import agora.crypto.Key;

import std.format;
import std.getopt;

/// Configuration parameter for Faucet
public struct Config
{
    /// configuration for tx generator
    public TxGenerator tx_generator;

    /// config for faucet web
    public Web web;
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
    public ConfigKey[] keys;

    /// PublicKeys of validators that Faucet will freeze stakes for
    public string[] validator_public_keys;

    /// Stats port (default: 9113)
    public ushort stats_port;
}

/// The Config for the faucet web
public struct Web
{
    /// Address to bind for website
    public string address;

    /// Port to bind for website
    public ushort port;
}

/// A KeyPair that can be parsed easily
public struct ConfigKey
{
    /// The underlying value
    public KeyPair value;

    ///
    public alias value this;

    /// Used by the config framework
    public static ConfigKey fromString (scope const(char)[] str) @safe
    {
        return ConfigKey(KeyPair.fromSeed(SecretKey.fromString(str)));
    }
}
