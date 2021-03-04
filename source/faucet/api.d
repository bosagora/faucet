/*******************************************************************************

    Definitions of the faucet API

    Copyright:
        Copyright (c) 2020 BOS Platform Foundation Korea
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module faucet.api;

import agora.common.Amount;
import agora.common.crypto.Key;
import agora.consensus.state.UTXOSet;
import agora.crypto.Hash;

import vibe.web.rest;
import vibe.http.common;

/*******************************************************************************

    Define the API the faucet exposes to the world

    The faucet can:
    - Return an array of all UTXOs known
    - Send `Amount` BOA to `KEY`, using owned UTXOs
    - Make `Transaction`s

*******************************************************************************/

@path("/")
public interface IFaucet
{
// The REST generator requires @safe methods
@safe:

    /***************************************************************************

        Returns:
          An array of all UTXOs known

        API:
          GET /utxos

    ***************************************************************************/

    @path("/utxos")
    public UTXO[Hash] getUTXOs ();

    /***************************************************************************

        Send `amount` BOA to `KEY`, using owned UTXOs

        API:
          POST /send

        Params:
          recv = the destination key
          amount = amount of BOA

    ***************************************************************************/

    @path("/send")
    public void sendTransaction (string recv, ulong amount);
}
