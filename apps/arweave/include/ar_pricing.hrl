%%% @doc Pricing macros.

%% The base wallet generation fee in USD, defined as a fraction.
%% The amount in AR depends on the current difficulty and height.
-define(WALLET_GEN_FEE_USD, {1, 10}).

%% Assumed number of replications in the long term.
-define(N_REPLICATIONS, 10).

%% Decay rate of the storage cost in GB/year.
-define(USD_PER_GBY_DECAY_ANNUAL, 0.995). % I.e., 0.5% annual decay rate.

%% The estimated historical price of storing 1GB of data for a year.
-define(USD_PER_GBY_2018, 0.001045).
-define(USD_PER_GBY_2019, 0.000925).

%% USD to AR exchange rates by height defined together with INITIAL_USD_TO_AR_HEIGHT
%% and INITIAL_USD_TO_AR_DIFF. The protocol uses these constants to estimate the
%% USD to AR rate at any block based on the change in the network difficulty and inflation
%% rewards.
-define(INITIAL_USD_TO_AR(Height), fun() ->
	Forks = {
		ar_fork:height_2_5()
	},
	case Forks of
		{Fork_2_5} when Height >= Fork_2_5 ->
			{1, 6} % TODO
	end
end).

%% The network difficulty at the time when the USD to AR exchange rate was
%% ?INITIAL_USD_TO_AR(Height). Used to account for the change in the network
%% difficulty when estimating the new USD to AR rate.
-define(INITIAL_USD_TO_AR_DIFF(Height), fun() ->
	Forks = {
		ar_fork:height_1_9(),
		ar_fork:height_2_2(),
		ar_fork:height_2_5()
	},
	case Forks of
		{_Fork_1_9, _Fork_2_2, Fork_2_5} when Height >= Fork_2_5 ->
			30; % TODO
		{_Fork_1_9, Fork_2_2, _Fork_2_5} when Height >= Fork_2_2 ->
			34;
		{Fork_1_9, _Fork_2_2, _Fork_2_5} when Height < Fork_1_9 ->
			28;
		_ ->
			29
	end
end).

%% The network height at the time when the USD to AR exchange rate was
%% ?INITIAL_USD_TO_AR(Height). Used to account for the change in inflation
%% rewards when estimating the new USD to AR rate.
-define(INITIAL_USD_TO_AR_HEIGHT(Height), fun() ->
	Forks = {
		ar_fork:height_1_9(),
		ar_fork:height_2_2(),
		ar_fork:height_2_5()
	},
	case Forks of
		{_Fork_1_9, _Fork_2_2, Fork_2_5} when Height >= Fork_2_5 ->
			Fork_2_5;
		{_Fork_1_9, Fork_2_2, _Fork_2_5} when Height >= Fork_2_2 ->
			Fork_2_2;
		{Fork_1_9, _Fork_2_2, _Fork_2_5} when Height < Fork_1_9 ->
			ar_fork:height_1_8();
		{Fork_1_9, _Fork_2_2, _Fork_2_5} ->
			Fork_1_9
	end
end).

%% The USD to AR rate is re-estimated every so many blocks.
-define(USD_TO_AR_ADJUSTMENT_FREQUENCY, 50).

%% Mining reward as a proportion of the estimated transaction storage costs.
-define(MINING_REWARD_MULTIPLIER, 0.2).

%% The USD to AR exchange rate for a new chain, e.g. a testnet.
-define(NEW_WEAVE_USD_TO_AR_RATE, {1, 4}).

%% The original USD to AR conversion rate, defined as a fraction. Set up at fork 2.4.
%% Used until the fork 2.5.
-define(USD_TO_AR_INITIAL_RATE, {1, 5}).

%% How much harder it should be to mine each
%% subsequent alternative POA option. Used until the fork 2.4.
-define(ALTERNATIVE_POA_DIFF_MULTIPLIER, 2).

%% Initial $/AR exchange rate. Used until the fork 2.4.
-define(INITIAL_USD_PER_AR(Height), fun() ->
	Forks = {
		ar_fork:height_1_9(),
		ar_fork:height_2_2()
	},
	case Forks of
		{Fork_1_9, _Fork_2_2} when Height < Fork_1_9 ->
			1.5;
		{_Fork_1_9, Fork_2_2} when Height >= Fork_2_2 ->
			4;
		_ ->
			1.2
	end
end).

%% Base wallet generation fee. Used until fork 2.2.
-define(WALLET_GEN_FEE, 250000000000).
