/*******************************************************************************

    Definitions of the faucet API

    Copyright:
        Copyright (c) 2020-2021 BOSAGORA Foundation
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module faucet.API;

import agora.common.Amount;
import agora.consensus.state.UTXOSet;
import agora.crypto.Hash;
import agora.crypto.Key;

import vibe.web.rest;
import vibe.http.common;

/*******************************************************************************

    Define the API the faucet exposes to the world

    The faucet can:
    - Return an array of all UTXOs known
    - Send 100 BOA to `KEY`, using owned UTXOs
    - Make `Transaction`s

*******************************************************************************/

@path("/")
public interface FaucetAPI
{
// The REST generator requires @safe methods
@safe:

    /***************************************************************************

        Returns:
          An array of all UTXOs known for `key`

        Params:
          key = The key to look up

        API:
          GET /utxos?key=boa1...

    ***************************************************************************/

    @path("/utxos")
    public UTXO[Hash] getUTXOs (PublicKey key);

    /***************************************************************************

        Send 100 BOA to `KEY`, using owned UTXOs

        API:
          POST /send

        Params:
          recv = the destination key

    ***************************************************************************/

    @path("/send")
    public void sendTransaction (@viaBody("recv") string recv);

    /***************************************************************************

        Create validator stake (40,000 BOA) for `KEY`, using owned UTXOs

        API:
          POST /stake

        Params:
          recv = the destination key

    ***************************************************************************/

    @path("/stake")
    public void createValidatorStake (@viaBody("recv") string recv);
}
