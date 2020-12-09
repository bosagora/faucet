/*******************************************************************************

    Definitions of the faucet API

    Copyright:
        Copyright (c) 2020 BOS Platform Foundation Korea
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module faucet.api;

import agora.common.Hash;
import agora.consensus.state.UTXOSet;

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
}
