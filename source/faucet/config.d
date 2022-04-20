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

import agora.common.Types;
import agora.consensus.data.Params;
import agora.crypto.Key;
import agora.utils.Log;

import configy.Attributes;

import std.format;
import std.getopt;

/// Configuration parameter for Faucet
public struct Config
{
    /// configuration for tx generator
    public TxGenerator tx_generator;

    /// Config for faucet web (disabled by default)
    public @Optional ListenerConfig web;

    /// Config for the stats interface (disabled by default)
    public @Optional ListenerConfig stats;

    /// Ledger persistence configuration
    public DataConfig data;

    /// Consensus configuration to match the network
    public ConsensusConfig consensus;

    /// Configuration for the Loggers
    @Key("name")
    public LoggerConfig[] logging = [ {
        name: null,
        level: LogLevel.Info,
        propagate: true,
        console: true,
        additive: true,
    } ];
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
    public Address[] addresses;

    /// Keys from the config
    public ConfigKey[] keys;

    /// PublicKeys of validators that Faucet will freeze stakes for
    public @Optional PublicKey[] validator_public_keys;
}

/// Describes an interface on which we listen
public struct ListenerConfig
{
    /// Address to bind to (netmask)
    public string address;

    /// Port to bind to
    public SetInfo!(ushort) port;

    ///
    public void validate () const
    {
        if (this.address.length && !this.port.set)
            throw new Exception("If 'address' is set, 'port' must be too");
        if (!this.address.length && this.port.set)
            throw new Exception("If 'port' is set, 'address' must be too");
        if (this.port.set && this.port.value == 0)
            throw new Exception("0 is not a valid value for port");
    }
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

/// Configuration for the Ledger
public struct DataConfig
{
    /// Whether the network is in testing mode or not
    public bool testing;

    public @Optional ubyte test_validators;

    /// Where to write the Ledger data to
    public string dir = "data";
}
