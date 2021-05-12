/*******************************************************************************

    Stats about the faucet

    Copyright:
        Copyright (c) 2021 BOSAGORA Foundation
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module faucet.stats;

import agora.stats.Stats;

///
public struct FaucetStatsValue
{
    public ulong faucet_transactions_sent_total;
}

///
public alias FaucetStats = Stats!(FaucetStatsValue, NoLabel);
