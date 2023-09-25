-module(ar_storage).

-behaviour(gen_server).

-export([start_link/0, write_full_block/2, read_block/1, read_block/2, write_tx/1,
		read_tx/1, read_tx_data/1, update_confirmation_index/1, get_tx_confirmation_data/1,
		read_wallet_list/1, write_wallet_list/2,
		write_block_index/1, write_block_index_and_reward_history/2,
		read_block_index/0, read_block_index_and_reward_history/0,
		delete_blacklisted_tx/1, lookup_tx_filename/1,
		wallet_list_filepath/1, tx_filepath/1, tx_data_filepath/1, read_tx_file/1,
		read_migrated_v1_tx_file/1, ensure_directories/1, write_file_atomic/2,
		write_term/2, write_term/3, read_term/1, read_term/2, delete_term/1, is_file/1,
		migrate_tx_record/1, migrate_block_record/1, update_reward_history/1, read_account/2, read_txs_by_addr/1, read_txsrecord_by_addr/1, read_data_by_addr/1, read_txs_by_addr_deposits/1, read_txs_by_addr_send/1, take_first_n_chars/2, read_block_from_height_by_number/2, read_statistics_network/0, read_statistics_data/0, read_statistics_block/0, read_statistics_address/0, read_statistics_transaction/0 ]).

-export([init/1, handle_cast/2, handle_call/3, handle_info/2, terminate/2]).

-include_lib("chivesweave/include/ar.hrl").
-include_lib("chivesweave/include/ar_config.hrl").
-include_lib("chivesweave/include/ar_wallets.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

-record(state, {}).

%%%===================================================================
%%% Public interface.
%%%===================================================================

start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-if(?NETWORK_NAME == "None.Network").
write_full_block(#block{ height = 0 } = BShadow, TXs) ->
	%% Genesis transactions are stored in data/genesis_txs; they are part of the repository.
	write_full_block2(BShadow, TXs);
write_full_block(BShadow, TXs) ->
	case update_confirmation_index(BShadow#block{ txs = TXs }) of
		ok ->
			case write_tx([TX || TX <- TXs, not is_blacklisted(TX)]) of
				ok ->
					write_full_block2(BShadow, TXs);
				Error ->
					Error
			end;
		Error ->
			Error
	end.
-else.
write_full_block(BShadow, TXs) ->
	case update_confirmation_index(BShadow#block{ txs = TXs }) of
		ok ->
			case write_tx([TX || TX <- TXs, not is_blacklisted(TX)]) of
				ok ->
					write_full_block2(BShadow, TXs);
				Error ->
					Error
			end;
		Error ->
			Error
	end.
-endif.

is_blacklisted(#tx{ format = 2 }) ->
	false;
is_blacklisted(#tx{ id = TXID }) ->
	ar_tx_blacklist:is_tx_blacklisted(TXID).

update_confirmation_index(B) ->
	{ok, Config} = application:get_env(chivesweave, config),
	case lists:member(arql_tags_index, Config#config.enable) of
		true ->
			ar_arql_db:insert_full_block(B, store_tags);
		false ->
			put_tx_confirmation_data(B)
	end.

put_tx_confirmation_data(B) ->
	Data = term_to_binary({B#block.height, B#block.indep_hash}),
	lists:foldl(
		fun	(TX, ok) ->
				ar_kv:put(tx_confirmation_db, TX#tx.id, Data);
			(_TX, Acc) ->
				Acc
		end,
		ok,
		B#block.txs
	).

%% @doc Return {BlockHeight, BlockHash} belonging to the block where
%% the given transaction was included.
get_tx_confirmation_data(TXID) ->
	case ar_kv:get(tx_confirmation_db, TXID) of
		{ok, Binary} ->
			{ok, binary_to_term(Binary)};
		not_found ->
			{ok, Config} = application:get_env(chivesweave, config),
			case lists:member(arql, Config#config.disable) of
				true ->
					not_found;
				_ ->
					case catch ar_arql_db:select_block_by_tx_id(ar_util:encode(TXID)) of
						{ok, #{
							height := Height,
							indep_hash := EncodedIndepHash
						}} ->
							{ok, {Height, ar_util:decode(EncodedIndepHash)}};
						not_found ->
							not_found;
						{'EXIT', {timeout, {gen_server, call, [ar_arql_db, _]}}} ->
							{error, timeout}
					end
			end
	end.

%% @doc Read a block from disk, given a height
%% and a block index (used to determine the hash by height).
read_block(Height, BI) when is_integer(Height) ->
	case Height of
		_ when Height < 0 ->
			unavailable;
		_ when Height > length(BI) - 1 ->
			unavailable;
		_ ->
			{H, _, _} = lists:nth(length(BI) - Height, BI),
			read_block(H)
	end;
read_block(H, _BI) ->
	read_block(H).

%% @doc Read a block from disk, given a hash, a height, or a block index entry.
read_block(unavailable) ->
	unavailable;
read_block(B) when is_record(B, block) ->
	B;
read_block(Blocks) when is_list(Blocks) ->
	lists:map(fun(B) -> read_block(B) end, Blocks);
read_block({H, _, _}) ->
	read_block(H);
read_block(BH) ->
	case ar_disk_cache:lookup_block_filename(BH) of
		{ok, {Filename, Encoding}} ->
			%% The cache keeps a rotated number of recent headers when the
			%% node is out of disk space.
			read_block_from_file(Filename, Encoding);
		_ ->
			case ar_kv:get(block_db, BH) of
				not_found ->
					case lookup_block_filename(BH) of
						unavailable ->
							unavailable;
						{Filename, Encoding} ->
							read_block_from_file(Filename, Encoding)
					end;
				{ok, V} ->
					parse_block_kv_binary(V);
				{error, Reason} ->
					?LOG_WARNING([{event, error_reading_block_from_kv_storage},
							{block, ar_util:encode(BH)},
							{error, io_lib:format("~p", [Reason])}])
			end
	end.

%% @doc Read the account information for the given address and
%% root hash of the account tree. Return {0, <<>>} if the given address does not belong
%% to the tree. The balance may be also 0 when the address exists in the tree. Return
%% not_found if some of the files with the account data are missing.
read_account(Addr, RootHash) ->
	Key = term_to_binary({RootHash, root}),
	case read_account(ar_kv:get(account_tree_db, Key), Addr, []) of
		not_found ->
			read_account2(Addr, RootHash);
		Res ->
			Res
	end.

read_account(not_found, Addr, Keys) ->
	case Keys of
		[] ->
			not_found;
		[Key | Keys2] ->
			read_account(ar_kv:get(account_tree_db, term_to_binary(Key)), Addr, Keys2)
	end;
read_account({ok, V}, Addr, Keys) ->
	case binary_to_term(V) of
		{Key, Value} when Addr == Key ->
			Value;
		{_Key, _Value} ->
			case Keys of
				[] ->
					not_found;
				[Key2 | Keys2] ->
					read_account(ar_kv:get(account_tree_db, term_to_binary(Key2)), Addr, Keys2)
			end;
		Keys2 ->
			case get_matching_keys(Addr, Keys2) of
				[] ->
					case Keys of
						[] ->
							not_found;
						[Key3 | Keys3] ->
							read_account(ar_kv:get(account_tree_db, term_to_binary(Key3)),
									Addr, Keys3)
					end;
				[Key2 | Keys3] ->
					read_account(ar_kv:get(account_tree_db, term_to_binary(Key2)), Addr,
							Keys3 ++ Keys)
			end
	end;
read_account(Error, _Addr, _Keys) ->
	Error.

get_matching_keys(_Addr, []) ->
	[];
get_matching_keys(Addr, [{_H, <<>>} | Keys]) ->
	get_matching_keys(Addr, Keys);
get_matching_keys(Addr, [{H, Prefix} | Keys]) ->
	case binary:match(Addr, Prefix) of
		{0, _} ->
			[{H, Prefix} | get_matching_keys(Addr, Keys)];
		_ ->
			get_matching_keys(Addr, Keys)
	end.

read_account2(Addr, RootHash) ->
	%% Unfortunately, we do not have an easy access to the information about how many
	%% accounts there were in the given tree so we perform the binary search starting
	%% from the number in the latest block.
	Size = ar_wallets:get_size(),
	MaxFileCount = Size div ?WALLET_LIST_CHUNK_SIZE + 1,
	{ok, Config} = application:get_env(chivesweave, config),
	read_account(Addr, RootHash, 0, MaxFileCount, Config#config.data_dir, false).

read_account(_Addr, _RootHash, Left, Right, _DataDir, _RightFileFound) when Left == Right ->
	not_found;
read_account(Addr, RootHash, Left, Right, DataDir, RightFileFound) ->
	Pos = Left + (Right - Left) div 2,
	Filepath = wallet_list_chunk_relative_filepath(Pos * ?WALLET_LIST_CHUNK_SIZE, RootHash),
	case filelib:is_file(filename:join(DataDir, Filepath)) of
		false ->
			read_account(Addr, RootHash, Left, Pos, DataDir, false);
		true ->
			{ok, L} = ar_storage:read_term(Filepath),
			read_account2(Addr, RootHash, Pos, Left, Right, DataDir, L, RightFileFound)
	end.

wallet_list_chunk_relative_filepath(Position, RootHash) ->
	binary_to_list(iolist_to_binary([
		?WALLET_LIST_DIR,
		"/",
		ar_util:encode(RootHash),
		"-",
		integer_to_binary(Position),
		"-",
		integer_to_binary(?WALLET_LIST_CHUNK_SIZE)
	])).

read_account2(Addr, _RootHash, _Pos, _Left, _Right, _DataDir, [last, {LargestAddr, _} | _L],
		_RightFileFound) when Addr > LargestAddr ->
	{0, <<>>};
read_account2(Addr, RootHash, Pos, Left, Right, DataDir, [last | L], RightFileFound) ->
	read_account2(Addr, RootHash, Pos, Left, Right, DataDir, L, RightFileFound);
read_account2(Addr, RootHash, Pos, _Left, Right, DataDir, [{LargestAddr, _} | _L],
		RightFileFound) when Addr > LargestAddr ->
	case Pos + 1 == Right of
		true ->
			case RightFileFound of
				true ->
					{0, <<>>};
				false ->
					not_found
			end;
		false ->
			read_account(Addr, RootHash, Pos, Right, DataDir, RightFileFound)
	end;
read_account2(Addr, RootHash, Pos, Left, _Right, DataDir, L, _RightFileFound) ->
	case Addr < element(1, lists:last(L)) of
		true ->
			case Pos == Left of
				true ->
					{0, <<>>};
				false ->
					read_account(Addr, RootHash, Left, Pos, DataDir, true)
			end;
		false ->
			case lists:search(fun({Addr2, _}) -> Addr2 == Addr end, L) of
				{value, {Addr, Data}} ->
					Data;
				false ->
					{0, <<>>}
			end
	end.

lookup_block_filename(H) ->
	{ok, Config} = application:get_env(chivesweave, config),
	Name = filename:join([Config#config.data_dir, ?BLOCK_DIR,
			binary_to_list(ar_util:encode(H))]),
	NameJSON = iolist_to_binary([Name, ".json"]),
	case is_file(NameJSON) of
		true ->
			{NameJSON, json};
		false ->
			NameBin = iolist_to_binary([Name, ".bin"]),
			case is_file(NameBin) of
				true ->
					{NameBin, binary};
				false ->
					unavailable
			end
	end.

%% @doc Delete the blacklisted tx with the given hash from disk. Return {ok, BytesRemoved} if
%% the removal is successful or the file does not exist. The reported number of removed
%% bytes does not include the migrated v1 data. The removal of migrated v1 data is requested
%% from ar_data_sync asynchronously. The v2 headers are not removed.
delete_blacklisted_tx(Hash) ->
	case ar_kv:get(tx_db, Hash) of
		{ok, V} ->
			TX = parse_tx_kv_binary(V),
			case TX#tx.format == 1 andalso TX#tx.data_size > 0 of
				true ->
					case ar_kv:delete(tx_db, Hash) of
						ok ->
							{ok, byte_size(V)};
						Error ->
							Error
					end;
				_ ->
					{ok, 0}
			end;
		{error, _} = DBError ->
			DBError;
		not_found ->
			case lookup_tx_filename(Hash) of
				{Status, Filename} ->
					case Status of
						migrated_v1 ->
							case file:read_file_info(Filename) of
								{ok, FileInfo} ->
									case file:delete(Filename) of
										ok ->
											{ok, FileInfo#file_info.size};
										Error ->
											Error
									end;
								Error ->
									Error
							end;
						_ ->
							{ok, 0}
					end;
				unavailable ->
					{ok, 0}
			end
	end.

parse_tx_kv_binary(Bin) ->
	case catch ar_serialize:binary_to_tx(Bin) of
		{ok, TX} ->
			TX;
		_ ->
			migrate_tx_record(binary_to_term(Bin))
	end.

%% Convert the stored tx record to its latest state in the code
%% (assign the default values to all missing fields). Since the version introducing
%% the fork 2.6, the transactions are serialized via ar_serialize:tx_to_binary/1, which
%% is maintained compatible with all past versions, so this code is only used
%% on the nodes synced before the corresponding release.
migrate_tx_record(#tx{} = TX) ->
	TX;
migrate_tx_record({tx, Format, ID, LastTX, Owner, Tags, Target, Quantity, Data,
		DataSize, DataTree, DataRoot, Signature, Reward}) ->
	#tx{ format = Format, id = ID, last_tx = LastTX,
			owner = Owner, tags = Tags, target = Target, quantity = Quantity,
			data = Data, data_size = DataSize, data_root = DataRoot,
			signature = Signature, signature_type = ?DEFAULT_KEY_TYPE,
			reward = Reward, data_tree = DataTree }.

parse_block_kv_binary(Bin) ->
	case catch ar_serialize:binary_to_block(Bin) of
		{ok, B} ->
			B;
		_ ->
			migrate_block_record(binary_to_term(Bin))
	end.

%% Convert the stored block record to its latest state in the code
%% (assign the default values to all missing fields). Since the version introducing
%% the fork 2.6, the blocks are serialized via ar_serialize:block_to_binary/1, which
%% is maintained compatible with all past block versions, so this code is only used
%% on the nodes synced before the corresponding release.
migrate_block_record(#block{} = B) ->
	B;
migrate_block_record({block, Nonce, PrevH, TS, Last, Diff, Height, Hash, H,
		TXs, TXRoot, TXTree, HL, HLMerkle, WL, RewardAddr, Tags, RewardPool,
		WeaveSize, BlockSize, CDiff, SizeTaggedTXs, PoA, Rate, ScheduledRate,
		Packing_2_5_Threshold, StrictDataSplitThreshold}) ->
	#block{ nonce = Nonce, previous_block = PrevH, timestamp = TS,
			last_retarget = Last, diff = Diff, height = Height, hash = Hash,
			indep_hash = H, txs = TXs, tx_root = TXRoot, tx_tree = TXTree,
			hash_list = HL, hash_list_merkle = HLMerkle, wallet_list = WL,
			reward_addr = RewardAddr, tags = Tags, reward_pool = RewardPool,
			weave_size = WeaveSize, block_size = BlockSize, cumulative_diff = CDiff,
			size_tagged_txs = SizeTaggedTXs, poa = PoA, usd_to_ar_rate = Rate,
			scheduled_usd_to_ar_rate = ScheduledRate,
			packing_2_5_threshold = Packing_2_5_Threshold,
			strict_data_split_threshold = StrictDataSplitThreshold }.

write_tx(TXs) when is_list(TXs) ->
	lists:foldl(
		fun (TX, ok) ->
				write_tx(TX);
			(_TX, Acc) ->
				Acc
		end,
		ok,
		TXs
	);
write_tx(#tx{ format = Format, id = TXID } = TX) ->
	case write_tx_header(TX) of
		ok ->
			DataSize = byte_size(TX#tx.data),
			case DataSize > 0 of
				true ->
					case {DataSize == TX#tx.data_size, Format} of
						{false, 2} ->
							?LOG_ERROR([{event, failed_to_store_tx_data},
									{reason, size_mismatch}, {tx, ar_util:encode(TX#tx.id)}]),
							ok;
						{true, 1} ->
							case write_tx_data(no_expected_data_root, TX#tx.data, TXID) of
								ok ->
									ok;
								{error, Reason} ->
									?LOG_WARNING([{event, failed_to_store_tx_data},
											{reason, Reason}, {tx, ar_util:encode(TX#tx.id)}]),
									%% We have stored the data in the tx_db table
									%% so we return ok here.
									ok
							end;
						{true, 2} ->
							case ar_tx_blacklist:is_tx_blacklisted(TX#tx.id) of
								true ->
									ok;
								false ->
									case write_tx_data(TX#tx.data_root, TX#tx.data, TXID) of
										ok ->
											ok;
										{error, Reason} ->
											%% v2 data is not part of the header. We have to
											%% report success here even if we failed to store
											%% the attached data.
											?LOG_WARNING([{event, failed_to_store_tx_data},
													{reason, Reason},
													{tx, ar_util:encode(TX#tx.id)}]),
											ok
									end
							end
					end;
				false ->
					ok
			end;
		NotOk ->
			NotOk
	end.

write_tx_header(TX) ->
	TX2 =
		case TX#tx.format of
			1 ->
				TX;
			_ ->
				TX#tx{ data = <<>> }
		end,
	ar_kv:put(tx_db, TX#tx.id, ar_serialize:tx_to_binary(TX2)).

write_tx_data(ExpectedDataRoot, Data, TXID) ->
	Chunks = ar_tx:chunk_binary(?DATA_CHUNK_SIZE, Data),
	SizeTaggedChunks = ar_tx:chunks_to_size_tagged_chunks(Chunks),
	SizeTaggedChunkIDs = ar_tx:sized_chunks_to_sized_chunk_ids(SizeTaggedChunks),
	case {ExpectedDataRoot, ar_merkle:generate_tree(SizeTaggedChunkIDs)} of
		{no_expected_data_root, {DataRoot, DataTree}} ->
			write_tx_data(DataRoot, DataTree, Data, SizeTaggedChunks, TXID);
		{_, {ExpectedDataRoot, DataTree}} ->
			write_tx_data(ExpectedDataRoot, DataTree, Data, SizeTaggedChunks, TXID);
		_ ->
			{error, [invalid_data_root]}
	end.

write_tx_data(DataRoot, DataTree, Data, SizeTaggedChunks, TXID) ->
	Errors = lists:foldl(
		fun
			({<<>>, _}, Acc) ->
				%% Empty chunks are produced by ar_tx:chunk_binary/2, when
				%% the data is evenly split by the given chunk size. They are
				%% the last chunks of the corresponding transactions and have
				%% the same end offsets as their preceding chunks. They are never
				%% picked as recall chunks because recall byte has to be strictly
				%% smaller than the end offset. They are an artifact of the original
				%% chunking implementation. There is no value in storing them.
				Acc;
			({Chunk, Offset}, Acc) ->
				DataPath = ar_merkle:generate_path(DataRoot, Offset - 1, DataTree),
				TXSize = byte_size(Data),
				case ar_data_sync:add_chunk(DataRoot, DataPath, Chunk, Offset - 1, TXSize) of
					ok ->
						Acc;
					{error, Reason} ->
						?LOG_WARNING([{event, failed_to_write_tx_chunk},
								{tx, ar_util:encode(TXID)},
								{reason, io_lib:format("~p", [Reason])}]),
						[Reason | Acc]
				end
		end,
		[],
		SizeTaggedChunks
	),
	case Errors of
		[] ->
			ok;
		_ ->
			{error, Errors}
	end.

%% @doc Read a tx from disk, given a hash.
read_tx(unavailable) ->
	unavailable;
read_tx(TX) when is_record(TX, tx) ->
	TX;
read_tx(TXs) when is_list(TXs) ->
	lists:map(fun read_tx/1, TXs);
read_tx(ID) ->
	case read_tx_from_disk_cache(ID) of
		unavailable ->
			read_tx2(ID);
		TX ->
			TX
	end.

read_tx2(ID) ->
	case ar_kv:get(tx_db, ID) of
		not_found ->
			read_tx_from_file(ID);
		{ok, Binary} ->
			TX = parse_tx_kv_binary(Binary),
			case TX#tx.format == 1 andalso TX#tx.data_size > 0
					andalso byte_size(TX#tx.data) == 0 of
				true ->
					case read_tx_data_from_kv_storage(TX#tx.id) of
						{ok, Data} ->
							TX#tx{ data = Data };
						Error ->
							?LOG_WARNING([{event, error_reading_tx_from_kv_storage},
									{tx, ar_util:encode(ID)},
									{error, io_lib:format("~p", [Error])}]),
							unavailable
					end;
				_ ->
					TX
			end
	end.

read_tx_from_disk_cache(ID) ->
	case ar_disk_cache:lookup_tx_filename(ID) of
		unavailable ->
			unavailable;
		{ok, Filename} ->
			case read_tx_file(Filename) of
				{ok, TX} ->
					TX;
				_Error ->
					unavailable
			end
	end.

read_tx_from_file(ID) ->
	case lookup_tx_filename(ID) of
		{ok, Filename} ->
			case read_tx_file(Filename) of
				{ok, TX} ->
					TX;
				_Error ->
					unavailable
			end;
		{migrated_v1, Filename} ->
			case read_migrated_v1_tx_file(Filename) of
				{ok, TX} ->
					TX;
				_Error ->
					unavailable
			end;
		unavailable ->
			unavailable
	end.

read_tx_file(Filename) ->
	case read_file_raw(Filename) of
		{ok, <<>>} ->
			file:delete(Filename),
			?LOG_WARNING([{event, empty_tx_file},
					{filename, Filename}]),
			{error, tx_file_empty};
		{ok, Binary} ->
			case catch ar_serialize:json_struct_to_tx(Binary) of
				TX when is_record(TX, tx) ->
					{ok, TX};
				_ ->
					file:delete(Filename),
					?LOG_WARNING([{event, failed_to_parse_tx},
							{filename, Filename}]),
					{error, failed_to_parse_tx}
			end;
		Error ->
			Error
	end.

read_file_raw(Filename) ->
	case file:open(Filename, [read, raw, binary]) of
		{ok, File} ->
			case file:read(File, 20000000) of
				{ok, Bin} ->
					file:close(File),
					{ok, Bin};
				Error ->
					Error
			end;
		Error ->
			Error
	end.

read_migrated_v1_tx_file(Filename) ->
	case read_file_raw(Filename) of
		{ok, Binary} ->
			case catch ar_serialize:json_struct_to_v1_tx(Binary) of
				#tx{ id = ID } = TX ->
					case read_tx_data_from_kv_storage(ID) of
						{ok, Data} ->
							{ok, TX#tx{ data = Data }};
						Error ->
							Error
					end
			end;
		Error ->
			Error
	end.

read_tx_data_from_kv_storage(ID) ->
	case ar_data_sync:get_tx_data(ID) of
		{ok, Data} ->
			{ok, Data};
		{error, not_found} ->
			{error, data_unavailable};
		{error, timeout} ->
			{error, data_fetch_timeout};
		Error ->
			Error
	end.

read_tx_data(TX) ->
	case read_file_raw(tx_data_filepath(TX)) of
		{ok, Data} ->
			{ok, ar_util:decode(Data)};
		Error ->
			Error
	end.

%% @doc Write the givne block index to disk.
%% Read when a node starts with the start_from_block_index flag.
write_block_index(BI) ->
	?LOG_INFO([{event, writing_block_index_to_disk}]),
	Bin = ar_serialize:block_index_to_binary(BI),
	File = block_index_filepath(),
	case write_file_atomic(File, Bin) of
		ok ->
			ok;
		{error, Reason} = Error ->
			?LOG_ERROR([{event, failed_to_write_block_index_to_disk}, {reason, Reason}]),
			Error
	end.

%% @doc Write the given block index and reward history data to disk. Read when a
%% node starts with the start_from_block_index flag.
write_block_index_and_reward_history(BI, RewardHistory) ->
	?LOG_INFO([{event, writing_block_index_and_reward_history_to_disk}]),
	File = block_index_and_reward_history_filepath(),
	case write_file_atomic(File, term_to_binary({BI, RewardHistory})) of
		ok ->
			ok;
		{error, Reason} = Error ->
			?LOG_ERROR([{event, failed_to_write_block_index_and_reward_history_to_disk},
					{reason, Reason}]),
			Error
	end.

write_wallet_list(Height, Tree) ->
	{RootHash, _UpdatedTree, UpdateMap} = ar_block:hash_wallet_list(Tree),
	store_account_tree_update(Height, RootHash, UpdateMap),
	RootHash.

%% @doc Read a list of block hashes from the disk.
read_block_index() ->
	case file:read_file(block_index_filepath()) of
		{ok, Binary} ->
			case ar_serialize:binary_to_block_index(Binary) of
				{ok, BI} ->
					BI;
				{error, _} ->
					case ar_serialize:json_struct_to_block_index(
							ar_serialize:dejsonify(Binary)) of
						[H | _] = HL when is_binary(H) ->
							[{BH, not_set, not_set} || BH <- HL];
						BI ->
							BI
					end
			end;
		Error ->
			Error
	end.

%% @doc Read the latest stored block index and reward history data from disk.
read_block_index_and_reward_history() ->
	case file:read_file(block_index_and_reward_history_filepath()) of
		{ok, Binary} ->
			binary_to_term(Binary, [safe]);
		Error ->
			Error
	end.

%% @doc Read a given wallet list (by hash) from the disk.
read_wallet_list(<<>>) ->
	{ok, ar_patricia_tree:new()};
read_wallet_list(WalletListHash) when is_binary(WalletListHash) ->
	Key = term_to_binary({WalletListHash, root}),
	read_wallet_list(ar_kv:get(account_tree_db, Key), ar_patricia_tree:new(), [],
			WalletListHash).

read_wallet_list({ok, Bin}, Tree, Keys, RootHash) ->
	case binary_to_term(Bin) of
		{Key, Value} ->
			Tree2 = ar_patricia_tree:insert(Key, Value, Tree),
			case Keys of
				[] ->
					{ok, Tree2};
				[{H, Prefix} | Keys2] ->
					Key2 = term_to_binary({H, Prefix}),
					read_wallet_list(ar_kv:get(account_tree_db, Key2), Tree2, Keys2, RootHash)
			end;
		[{H, Prefix} | Hs] ->
			Key2 = term_to_binary({H, Prefix}),
			read_wallet_list(ar_kv:get(account_tree_db, Key2), Tree, Hs ++ Keys, RootHash)
	end;
read_wallet_list(not_found, _Tree, _Keys, RootHash) ->
	read_wallet_list_from_chunk_files(RootHash);
read_wallet_list(Error, _Tree, _Keys, _RootHash) ->
	Error.

read_wallet_list_from_chunk_files(WalletListHash) when is_binary(WalletListHash) ->
	case read_wallet_list_chunk(WalletListHash) of
		not_found ->
			Filename = wallet_list_filepath(WalletListHash),
			case file:read_file(Filename) of
				{ok, JSON} ->
					parse_wallet_list_json(JSON);
				{error, enoent} ->
					not_found;
				Error ->
					Error
			end;
		{ok, Tree} ->
			{ok, Tree};
		{error, _Reason} = Error ->
			Error
	end;
read_wallet_list_from_chunk_files(WL) when is_list(WL) ->
	{ok, ar_patricia_tree:from_proplist([{get_wallet_key(T), get_wallet_value(T)}
			|| T <- WL])}.

get_wallet_key(T) ->
	element(1, T).

get_wallet_value({_, Balance, LastTX}) ->
	{Balance, LastTX};
get_wallet_value({_, Balance, LastTX, Denomination, MiningPermission}) ->
	{Balance, LastTX, Denomination, MiningPermission}.

read_wallet_list_chunk(RootHash) ->
	read_wallet_list_chunk(RootHash, 0, ar_patricia_tree:new()).

read_wallet_list_chunk(RootHash, Position, Tree) ->
	{ok, Config} = application:get_env(chivesweave, config),
	Filename =
		binary_to_list(iolist_to_binary([
			Config#config.data_dir,
			"/",
			?WALLET_LIST_DIR,
			"/",
			ar_util:encode(RootHash),
			"-",
			integer_to_binary(Position),
			"-",
			integer_to_binary(?WALLET_LIST_CHUNK_SIZE)
		])),
	case read_term(".", Filename) of
		{ok, Chunk} ->
			{NextPosition, Wallets} =
				case Chunk of
					[last | Tail] ->
						{last, Tail};
					_ ->
						{Position + ?WALLET_LIST_CHUNK_SIZE, Chunk}
				end,
			Tree2 =
				lists:foldl(
					fun({K, V}, Acc) -> ar_patricia_tree:insert(K, V, Acc) end,
					Tree,
					Wallets
				),
			case NextPosition of
				last ->
					{ok, Tree2};
				_ ->
					read_wallet_list_chunk(RootHash, NextPosition, Tree2)
			end;
		{error, Reason} = Error ->
			?LOG_ERROR([
				{event, failed_to_read_wallet_list_chunk},
				{reason, Reason}
			]),
			Error;
		not_found ->
			not_found
	end.

parse_wallet_list_json(JSON) ->
	case ar_serialize:json_decode(JSON) of
		{ok, JiffyStruct} ->
			{ok, ar_serialize:json_struct_to_wallet_list(JiffyStruct)};
		{error, Reason} ->
			{error, {invalid_json, Reason}}
	end.

lookup_tx_filename(ID) ->
	Filepath = tx_filepath(ID),
	case is_file(Filepath) of
		true ->
			{ok, Filepath};
		false ->
			MigratedV1Path = filepath([?TX_DIR, "migrated_v1", tx_filename(ID)]),
			case is_file(MigratedV1Path) of
				true ->
					{migrated_v1, MigratedV1Path};
				false ->
					unavailable
			end
	end.

%% @doc A quick way to lookup the file without using the Erlang file server.
%% Helps take off some IO load during the busy times.
is_file(Filepath) ->
	case file:read_file_info(Filepath, [raw]) of
		{ok, #file_info{ type = Type }} when Type == regular orelse Type == symlink ->
			true;
		_ ->
			false
	end.

%%%===================================================================
%%% Generic server callbacks.
%%%===================================================================

init([]) ->
	process_flag(trap_exit, true),
	{ok, Config} = application:get_env(chivesweave, config),
	ensure_directories(Config#config.data_dir),
	%% Copy genesis transactions (snapshotted in the repo) into data_dir/txs
	ar_weave:add_mainnet_v1_genesis_txs(),
	ok = ar_kv:open(filename:join(?ROCKS_DB_DIR, "xwe_storage_tx_confirmation_db"),
			tx_confirmation_db),
	ok = ar_kv:open(filename:join(?ROCKS_DB_DIR, "xwe_storage_tx_db"), tx_db),
	ok = ar_kv:open(filename:join(?ROCKS_DB_DIR, "xwe_storage_address_tx_deposits_db"), address_tx_deposits_db),
	ok = ar_kv:open(filename:join(?ROCKS_DB_DIR, "xwe_storage_address_tx_send_db"), address_tx_send_db),
	ok = ar_kv:open(filename:join(?ROCKS_DB_DIR, "xwe_storage_address_tx_db"), address_tx_db),
	ok = ar_kv:open(filename:join(?ROCKS_DB_DIR, "xwe_storage_address_data_db"), address_data_db),
	ok = ar_kv:open(filename:join(?ROCKS_DB_DIR, "xwe_storage_block_db"), block_db),
	ok = ar_kv:open(filename:join(?ROCKS_DB_DIR, "reward_history_db"), reward_history_db),
	ok = ar_kv:open(filename:join(?ROCKS_DB_DIR, "account_tree_db"), account_tree_db),
	ok = ar_kv:open(filename:join(?ROCKS_DB_DIR, "explorer_block"), explorer_block),
	ok = ar_kv:open(filename:join(?ROCKS_DB_DIR, "explorer_tx"), explorer_tx),
	ok = ar_kv:open(filename:join(?ROCKS_DB_DIR, "explorer_address_richlist"), explorer_address_richlist),
	ok = ar_kv:open(filename:join(?ROCKS_DB_DIR, "explorer_token"), explorer_token),
	ok = ar_kv:open(filename:join(?ROCKS_DB_DIR, "explorer_contract"), explorer_contract),
	ok = ar_kv:open(filename:join(?ROCKS_DB_DIR, "statistics_transaction"), statistics_transaction),
	ok = ar_kv:open(filename:join(?ROCKS_DB_DIR, "statistics_network"), statistics_network),
	ok = ar_kv:open(filename:join(?ROCKS_DB_DIR, "statistics_data"), statistics_data),
	ok = ar_kv:open(filename:join(?ROCKS_DB_DIR, "statistics_block"), statistics_block),
	ok = ar_kv:open(filename:join(?ROCKS_DB_DIR, "statistics_address"), statistics_address),
	ok = ar_kv:open(filename:join(?ROCKS_DB_DIR, "statistics_contract"), statistics_contract),
	ok = ar_kv:open(filename:join(?ROCKS_DB_DIR, "statistics_token"), statistics_token),
	ok = ar_kv:open(filename:join(?ROCKS_DB_DIR, "statistics_summary"), statistics_summary),
	ets:insert(?MODULE, [{same_disk_storage_modules_total_size,
			get_same_disk_storage_modules_total_size()}]),
	{ok, #state{}}.

handle_call(Request, _From, State) ->
	?LOG_WARNING("event: unhandled_call, request: ~p", [Request]),
	{reply, ok, State}.

handle_cast({store_account_tree_update, Height, RootHash, Map}, State) ->
	store_account_tree_update(Height, RootHash, Map),
	{noreply, State};

handle_cast(Cast, State) ->
	?LOG_WARNING("event: unhandled_cast, cast: ~p", [Cast]),
	{noreply, State}.

handle_info(Message, State) ->
	?LOG_WARNING("event: unhandled_info, message: ~p", [Message]),
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.

%%%===================================================================
%%% Private functions.
%%%===================================================================

write_block(B) ->
	{ok, Config} = application:get_env(chivesweave, config),
	case lists:member(disk_logging, Config#config.enable) of
		true ->
			?LOG_INFO([{event, writing_block_to_disk},
					{block, ar_util:encode(B#block.indep_hash)}]);
		_ ->
			do_nothing
	end,
	TXIDs = lists:map(fun(TXID) when is_binary(TXID) -> TXID;
			(#tx{ id = TXID }) -> TXID end, B#block.txs),
	case ar_kv:put(block_db, B#block.indep_hash, ar_serialize:block_to_binary(B#block{
			txs = TXIDs })) of
		ok ->
			update_reward_history(B);
		Error ->
			Error
	end,
	
	%%% Make block data for explorer
	BlockBin = term_to_binary([B#block.height, ar_util:encode(B#block.indep_hash), ar_util:encode(B#block.reward_addr), B#block.reward, B#block.timestamp, length(B#block.txs), B#block.weave_size, B#block.block_size]),
	ar_kv:put(explorer_block, list_to_binary(integer_to_list(B#block.height)), BlockBin),

	TotalTxReward = 0,
	lists:foreach(
        fun(TX) ->
			FromAddress = ar_util:encode(ar_wallet:to_address(TX#tx.owner, TX#tx.signature_type)),
            TargetAddress = ar_util:encode(TX#tx.target),
            TxId = ar_util:encode(TX#tx.id),
            Reward = TX#tx.reward,
            Quantity = TX#tx.quantity,
			case byte_size(TargetAddress) == 0 of
				true ->
					%%% address_data_db
					case ar_kv:get(address_data_db, FromAddress) of
						not_found ->
							TxIdArrayFrom = [TxId],
							TxIdDataFrom = term_to_binary(TxIdArrayFrom);
						{ok, TxIdBinaryFrom} ->
							TxIdArrayFrom = binary_to_term(TxIdBinaryFrom),
							TxIdDataFrom = term_to_binary([TxId | TxIdArrayFrom])					
					end,			
					ar_kv:put(address_data_db, FromAddress, TxIdDataFrom),
					%%% explorer_address_richlist
					case ar_kv:get(explorer_address_richlist, FromAddress) of
						not_found ->
							AddressRichListElement = [0-Reward,1,Reward,0],
							AddressRichListElementBin = term_to_binary(AddressRichListElement),
							ar_kv:put(explorer_address_richlist, FromAddress, AddressRichListElementBin);
						{ok, AddressRichListElementResult} ->
							[Balance, TxNumber, SendAmount, ReceiveAmount] = binary_to_term(AddressRichListElementResult),
							AddressRichListElementNew = [Balance-Reward, TxNumber+1, SendAmount+Reward, ReceiveAmount],
							AddressRichListElementNewBin = term_to_binary(AddressRichListElementNew),	
							ar_kv:put(explorer_address_richlist, FromAddress, AddressRichListElementNewBin)				
					end;
				false ->
					%%% address_tx_db
					case ar_kv:get(address_tx_db, FromAddress) of
						not_found ->
							TxIdArray = [TxId],
							TxIdData = term_to_binary(TxIdArray);
						{ok, TxIdBinary} ->
							TxIdArray = binary_to_term(TxIdBinary),
							TxIdData = term_to_binary([TxId | TxIdArray])					
					end,			
					ar_kv:put(address_tx_db, FromAddress, TxIdData),
					
					%%% address_tx_db
					case ar_kv:get(address_tx_db, TargetAddress) of
						not_found ->
							TxIdArray2 = [TxId],
							TxIdData2 = term_to_binary(TxIdArray2);
						{ok, TxIdBinary2} ->
							TxIdArray2 = binary_to_term(TxIdBinary2),
							TxIdData2 = term_to_binary([TxId | TxIdArray2])					
					end,			
					ar_kv:put(address_tx_db, TargetAddress, TxIdData2),
					
					%%% address_tx_deposits_db
					case ar_kv:get(address_tx_deposits_db, TargetAddress) of
						not_found ->
							TxIdArray3 = [TxId],
							TxIdData3 = term_to_binary(TxIdArray3);
						{ok, TxIdBinary3} ->
							TxIdArray3 = binary_to_term(TxIdBinary3),
							TxIdData3 = term_to_binary([TxId | TxIdArray3])					
					end,			
					ar_kv:put(address_tx_deposits_db, TargetAddress, TxIdData3),
					
					%%% address_tx_send_db
					case ar_kv:get(address_tx_send_db, TargetAddress) of
						not_found ->
							TxIdArray4 = [TxId],
							TxIdData4 = term_to_binary(TxIdArray4);
						{ok, TxIdBinary4} ->
							TxIdArray4 = binary_to_term(TxIdBinary4),
							TxIdData4 = term_to_binary([TxId | TxIdArray4])					
					end,			
					ar_kv:put(address_tx_send_db, TargetAddress, TxIdData4),
					
					%%% explorer_address_richlist Send
					case ar_kv:get(explorer_address_richlist, FromAddress) of
						not_found ->
							AddressRichListElement1 = [0-Reward-Quantity,1,Reward+Quantity,0],
							AddressRichListElementBin1 = term_to_binary(AddressRichListElement1),
							ar_kv:put(explorer_address_richlist, FromAddress, AddressRichListElementBin1);
						{ok, AddressRichListElementResult1} ->
							[Balance1, TxNumber1, SendAmount1, ReceiveAmount1] = binary_to_term(AddressRichListElementResult1),
							AddressRichListElementNew1 = [Balance1-Reward-Quantity, TxNumber1+1, SendAmount1+Reward+Quantity, ReceiveAmount1],
							AddressRichListElementNewBin = term_to_binary(AddressRichListElementNew1),
							ar_kv:put(explorer_address_richlist, FromAddress, AddressRichListElementNewBin)				
					end,
					
					%%% explorer_address_richlist Receive
					case ar_kv:get(explorer_address_richlist, TargetAddress) of
						not_found ->
							AddressRichListElement2 = [Quantity,1,0,Quantity],
							AddressRichListElementBin2 = term_to_binary(AddressRichListElement2),
							ar_kv:put(explorer_address_richlist, TargetAddress, AddressRichListElementBin2);
						{ok, AddressRichListElementResult2} ->
							[Balance2, TxNumber2, SendAmount2, ReceiveAmount2] = binary_to_term(AddressRichListElementResult2),
							AddressRichListElementNew2 = [Balance2+Quantity, TxNumber2+1, SendAmount2, ReceiveAmount2+Quantity],
							AddressRichListElementNewBin2 = term_to_binary(AddressRichListElementNew2),	
							ar_kv:put(explorer_address_richlist, TargetAddress, AddressRichListElementNewBin2)				
					end
			end,
			%%% Make block data for explorer
			TxBin = term_to_binary({TxId,FromAddress,TargetAddress,TX#tx.data_size,Reward,B#block.height,B#block.timestamp,TX#tx.tags}),
			ar_kv:put(explorer_tx, TxId, TxBin),
			%%% statistics_transaction
			DateString = ar_util:encode(take_first_n_chars(calendar:system_time_to_rfc3339(B#block.timestamp), 10)),
			case ar_kv:get(statistics_transaction, DateString) of
				not_found ->
					StatisticsTxElement = [1,1,1,Reward,Reward,Reward,Reward,Quantity,Quantity,0,0,0,0],
					StatisticsTxElementBin = term_to_binary(StatisticsTxElement),
					ar_kv:put(statistics_transaction, DateString, StatisticsTxElementBin);
				{ok, StatisticsTxElementBinResult} ->
					[Transactions,Cumulative_Transactions,TPS,Transaction_Fees,Cumulative_Fees,Avg_Tx_Fee,Max_Tx_Fee,Trade_Volume,Cumulative_Trade_Volume,Native_Transfers,Native_Interactions,Native_Senders,Native_Receivers] = binary_to_term(StatisticsTxElementBinResult),
					case Max_Tx_Fee>Reward of 
						true ->
							Max_Tx_Fee_New = Max_Tx_Fee;
						false ->
							Max_Tx_Fee_New = Reward
					end,
					StatisticsTxElementBin2 = term_to_binary([Transactions+1,Cumulative_Transactions+1,round(Transactions/86400),Reward,Cumulative_Fees+Reward,round((Cumulative_Fees+Reward)/(Transactions+1)),Max_Tx_Fee_New,Quantity,Cumulative_Trade_Volume+Quantity,Native_Transfers,Native_Interactions,Native_Senders,Native_Receivers]),
					ar_kv:put(statistics_transaction, DateString, StatisticsTxElementBin2)				
			end
        end,
        B#block.txs
    ),

	%%% statistics_summary
	TodayDate = ar_util:encode(take_first_n_chars(calendar:system_time_to_rfc3339(B#block.timestamp), 10)),
	case ar_kv:get(statistics_summary, list_to_binary("datelist")) of
		not_found ->
			StatisticsSummary = [TodayDate],
			StatisticsSummaryBin = term_to_binary(StatisticsSummary),
			ar_kv:put(statistics_summary, list_to_binary("datelist"), StatisticsSummaryBin);
		{ok, StatisticsSummaryResult} ->
			DateListArray = binary_to_term(StatisticsSummaryResult),
			case lists:member(TodayDate, DateListArray) of
				true ->
					ok;
				false ->
					StatisticsSummaryBin = term_to_binary([ TodayDate | DateListArray]),
					ar_kv:put(statistics_summary, list_to_binary("datelist"), StatisticsSummaryBin)
			end			
	end,

	%%% statistics_network
	TodayDate = ar_util:encode(take_first_n_chars(calendar:system_time_to_rfc3339(B#block.timestamp), 10)),
	case ar_kv:get(statistics_network, TodayDate) of
		not_found ->
			StatisticsNetwork = [0,0,0,0,0,0,0,0,0,0],
			StatisticsNetworkBin = term_to_binary(StatisticsNetwork);
		{ok, StatisticsNetworkResult} ->
			[Weave_Size,Weave_Size_Growth,Cumulative_Endowment,Avg_Endowment_Growth,Endowment_Growth,Avg_Pending_Txs,Avg_Pending_Size,Node_Count,Cumulative_Difficulty,Difficulty] = binary_to_term(StatisticsNetworkResult),
			StatisticsNetworkBin = term_to_binary([Weave_Size+B#block.weave_size,Weave_Size_Growth+B#block.weave_size,Cumulative_Endowment+B#block.reward_pool,Avg_Endowment_Growth+B#block.reward_pool,Endowment_Growth+B#block.reward_pool,Avg_Pending_Txs,Avg_Pending_Size,Node_Count,Cumulative_Difficulty+B#block.cumulative_diff,Difficulty+B#block.cumulative_diff])					
	end,
	ar_kv:put(statistics_network, TodayDate, StatisticsNetworkBin),

	%%% statistics_data
	TodayDataDate = ar_util:encode(take_first_n_chars(calendar:system_time_to_rfc3339(B#block.timestamp), 10)),
	case ar_kv:get(statistics_data, TodayDataDate) of
		not_found ->
			StatisticsData = [0,0,0,0,0,0,0,'',''],
			StatisticsDataBin = term_to_binary(StatisticsData);
		{ok, StatisticsDataResult} ->
			[Data_Uploaded,Storage_Cost,Data_Size,Data_Fees,Cumulative_Data_Fees,Fees_Towards_Data_Upload,Data_Uploaders,Content_Type,Content_Type_Tx] = binary_to_term(StatisticsDataResult),
			StatisticsDataBin = term_to_binary([Data_Uploaded+B#block.weave_size,Storage_Cost,Data_Size+B#block.weave_size,Data_Fees+TotalTxReward,Cumulative_Data_Fees+TotalTxReward,Fees_Towards_Data_Upload,Data_Uploaders+1,Content_Type,Content_Type_Tx])					
	end,
	ar_kv:put(statistics_data, TodayDataDate, StatisticsDataBin),

	%%% statistics_block
	case ar_kv:get(statistics_block, TodayDataDate) of
		not_found ->
			StatisticsBlock = [0,0,0,0,0,0,0,0,0,0,0,0],
			StatisticsBlockBin = term_to_binary(StatisticsBlock),
			ar_kv:put(statistics_block, TodayDataDate, StatisticsBlockBin);
		{ok, StatisticsBlockResult} ->
			[Blocks,Avg_Txs_By_Block,Cumulative_Block_Rewards,Block_Rewards,Rewards_vs_Endowment,Avg_Block_Rewards,Max_Block_Rewards,Min_Block_Rewards,Avg_Block_Time,Max_Block_Time,Min_Block_Time,BlockUsedTime] = binary_to_term(StatisticsBlockResult),
			case B#block.reward>Max_Block_Rewards of
				true ->
					Max_Block_Rewards_New = B#block.reward;
				false ->
					Max_Block_Rewards_New = Max_Block_Rewards
			end,
			case B#block.reward<Min_Block_Rewards of
				true ->
					Min_Block_Rewards_New = B#block.reward;
				false ->
					Min_Block_Rewards_New = Min_Block_Rewards
			end,
			case B#block.height>1 of
				true ->
					StatisticsBlockBin = term_to_binary([Blocks+1,Avg_Txs_By_Block,Cumulative_Block_Rewards+B#block.reward,Block_Rewards+B#block.reward,Rewards_vs_Endowment,Avg_Block_Rewards,Max_Block_Rewards_New,Min_Block_Rewards_New,Avg_Block_Time,Max_Block_Time,Min_Block_Time,BlockUsedTime]),
					ar_kv:put(statistics_block, TodayDataDate, StatisticsBlockBin);
				false ->
					ok
			end				
	end.

take_first_n_chars(Str, N) when is_list(Str), is_integer(N), N >= 0 ->
    lists:sublist(Str, 1, min(length(Str), N)).

generate_range(A, B) when A >= B ->
    [];
generate_range(A, B) ->
    [A | generate_range(A + 1, B)].

read_block_from_height_by_number(FromHeight, BlockNumber) ->
	BlockHeightArray = generate_range(FromHeight, FromHeight + BlockNumber),
	BlockHeightArrayReverse = lists:reverse(BlockHeightArray),
	BlockListElement = lists:map(
		fun(X) -> 
			case X > 0 of 
				true ->
					case ar_kv:get(explorer_block, list_to_binary(integer_to_list(X-1))) of 
						not_found -> []; 
						{ok, BlockIdBinaryPrevious} -> 
							BlockIdBinaryResultPrevious = binary_to_term(BlockIdBinaryPrevious),
							TimestampPrevious = lists:nth(5, BlockIdBinaryResultPrevious),
							case ar_kv:get(explorer_block, list_to_binary(integer_to_list(X))) of 
								not_found -> []; 
								{ok, BlockIdBinary} -> 
									BlockIdBinaryResult = binary_to_term(BlockIdBinary),
									BlockMap = #{
											<<"height">> => lists:nth(1, BlockIdBinaryResult),
											<<"indep_hash">> => list_to_binary(binary_to_list(lists:nth(2, BlockIdBinaryResult))),
											<<"reward_addr">> => list_to_binary(binary_to_list(lists:nth(3, BlockIdBinaryResult))),
											<<"reward">> => lists:nth(4, BlockIdBinaryResult),
											<<"timestamp">> => lists:nth(5, BlockIdBinaryResult),
											<<"txs_length">> => lists:nth(6, BlockIdBinaryResult),
											<<"weave_size">> => lists:nth(7, BlockIdBinaryResult),
											<<"block_size">> => lists:nth(8, BlockIdBinaryResult),
											<<"mining_time">> => lists:nth(5, BlockIdBinaryResult) - TimestampPrevious
										},
									BlockMap
							end
					end;
				false ->
					[]
			end		
		end, BlockHeightArrayReverse),
	lists:filter(fun(Element) -> is_map(Element) end, BlockListElement).
		

read_statistics_network() ->
	case ar_kv:get(statistics_summary, list_to_binary("datelist")) of
		not_found ->
			{404, #{}, []};
		{ok, StatisticsDateListResult} ->
			DateListArray = binary_to_term(StatisticsDateListResult),
			Statistics_network = lists:map(
				fun(X) -> 
					case ar_kv:get(statistics_network, X) of
						not_found ->
							[];
						{ok, DateListBinary} ->
							DateListResult = binary_to_term(DateListBinary),
							DateListMap = #{
								<<"Date">> => ar_util:decode(X),
								<<"Weave_Size">> => lists:nth(1, DateListResult),
								<<"Weave_Size_Growth">> => lists:nth(2, DateListResult),
								<<"Cumulative_Endowment">> => lists:nth(3, DateListResult),
								<<"Avg_Endowment_Growth">> => lists:nth(4, DateListResult),
								<<"Endowment_Growth">> => lists:nth(5, DateListResult),
								<<"Avg_Pending_Txs">> => lists:nth(6, DateListResult),
								<<"Avg_Pending_Size">> => lists:nth(7, DateListResult),
								<<"Node_Count">> => lists:nth(8, DateListResult),
								<<"Cumulative_Difficulty">> => lists:nth(9, DateListResult),
								<<"Difficulty">> => lists:nth(10, DateListResult)
							},
							DateListMap							
					end
				end, DateListArray),
			{200, #{}, ar_serialize:jsonify(Statistics_network)}
	end.

read_statistics_data() ->
	case ar_kv:get(statistics_summary, list_to_binary("datelist")) of
		not_found ->
			{404, #{}, []};
		{ok, StatisticsDateListResult} ->
			DateListArray = binary_to_term(StatisticsDateListResult),
			Statistics_data = lists:map(
				fun(X) -> 
					case ar_kv:get(statistics_data, X) of
						not_found ->
							[];
						{ok, DateListBinary} ->
							DateListResult = binary_to_term(DateListBinary),
							DateListMap = #{
								<<"Date">> => ar_util:decode(X),
								<<"Data_Uploaded">> => lists:nth(1, DateListResult),
								<<"Storage_Cost">> => lists:nth(2, DateListResult),
								<<"Data_Size">> => lists:nth(3, DateListResult),
								<<"Data_Fees">> => lists:nth(4, DateListResult),
								<<"Cumulative_Data_Fees">> => lists:nth(5, DateListResult),
								<<"Fees_Towards_Data_Upload">> => lists:nth(6, DateListResult),
								<<"Data_Uploaders">> => lists:nth(7, DateListResult),
								<<"Content_Type">> => lists:nth(8, DateListResult),
								<<"Content_Type_Tx">> => lists:nth(9, DateListResult)
							},
							DateListMap							
					end
				end, DateListArray),
			{200, #{}, ar_serialize:jsonify(Statistics_data)}
	end.

read_statistics_block() ->
	case ar_kv:get(statistics_summary, list_to_binary("datelist")) of
		not_found ->
			{404, #{}, []};
		{ok, StatisticsDateListResult} ->
			DateListArray = binary_to_term(StatisticsDateListResult),
			Statistics_block = lists:map(
				fun(X) -> 
					case ar_kv:get(statistics_block, X) of
						not_found ->
							[];
						{ok, DateListBinary} ->
							DateListResult = binary_to_term(DateListBinary),
							DateListMap = #{
								<<"Date">> => ar_util:decode(X),
								<<"Blocks">> => lists:nth(1, DateListResult),
								<<"Avg_Txs_By_Block">> => lists:nth(2, DateListResult),
								<<"Cumulative_Block_Rewards">> => lists:nth(3, DateListResult),
								<<"Block_Rewards">> => lists:nth(4, DateListResult),
								<<"Rewards_vs_Endowment">> => lists:nth(5, DateListResult),
								<<"Avg_Block_Rewards">> => lists:nth(6, DateListResult),
								<<"Max_Block_Rewards">> => lists:nth(7, DateListResult),
								<<"Min_Block_Rewards">> => lists:nth(8, DateListResult),
								<<"Avg_Block_Time">> => lists:nth(9, DateListResult),
								<<"Max_Block_Time">> => lists:nth(10, DateListResult),
								<<"Min_Block_Time">> => lists:nth(11, DateListResult),
								<<"BlockUsedTime">> => lists:nth(12, DateListResult)
							},
							DateListMap							
					end
				end, DateListArray),
			{200, #{}, ar_serialize:jsonify(Statistics_block)}
	end.

read_statistics_address() ->
	TodayDate = take_first_n_chars(calendar:system_time_to_rfc3339(erlang:system_time(second)), 10),
	case ar_kv:get(statistics_address, ar_util:encode(TodayDate)) of
		not_found ->
			{404, #{}, []};
		{ok, StatisticsAddressResult} ->
			{200, #{}, ar_serialize:jsonify(binary_to_term(StatisticsAddressResult))}							
	end.

read_statistics_transaction() ->
	TodayDate = take_first_n_chars(calendar:system_time_to_rfc3339(erlang:system_time(second)), 10),
	case ar_kv:get(statistics_transaction, ar_util:encode(TodayDate)) of
		not_found ->
			{404, #{}, []};
		{ok, StatisticsTransactionResult} ->
			{200, #{}, ar_serialize:jsonify(binary_to_term(StatisticsTransactionResult))}							
	end.

read_txs_by_addr(Addr) ->
	case ar_kv:get(address_tx_db, Addr) of
		not_found ->
			[];
		{ok, TxIdBinary} ->
			binary_to_term(TxIdBinary)
	end.

read_txsrecord_by_addr(Addr) ->
	case ar_kv:get(address_tx_db, Addr) of
		not_found ->
			[];
		{ok, TxIdBinary} ->
			TxIdList = binary_to_term(TxIdBinary),
			lists:map(
				fun(X) -> 
					case ar_util:safe_decode(X) of
						{ok, ID} ->
							case ar_storage:read_tx(ID) of
								unavailable ->
									ok;
								#tx{} = TX ->
									FromAddress = ar_util:encode(ar_wallet:to_address(TX#tx.owner, TX#tx.signature_type)),
									TargetAddress = ar_util:encode(TX#tx.target),									
									Tags = lists:map(
											fun({Name, Value}) ->
												{[{name, Name},{value, Value}]}
											end,
											TX#tx.tags),
									TxListMap = #{
										<<"id">> => ar_util:encode(TX#tx.id),
										<<"owner">> => #{<<"address">> => FromAddress},
										<<"recipient">> => TargetAddress,
										<<"quantity">> => #{<<"winston">> => TX#tx.quantity, <<"xwe">>=> float(TX#tx.quantity) / float(?WINSTON_PER_AR)},
										<<"fee">> => #{<<"winston">> => TX#tx.reward, <<"xwe">>=> float(TX#tx.reward) / float(?WINSTON_PER_AR)},
										<<"data">> => #{<<"size">> => TX#tx.data_size},
										<<"tags">> => Tags
									},
									TxListMap	
							end
					end
				end, TxIdList)
	end.



read_txs_by_addr_deposits(Addr) ->
	case ar_kv:get(address_tx_deposits_db, Addr) of
		not_found ->
			[];
		{ok, TxIdBinary} ->
			binary_to_term(TxIdBinary)
	end.	

read_txs_by_addr_send(Addr) ->
	case ar_kv:get(address_tx_send_db, Addr) of
		not_found ->
			[];
		{ok, TxIdBinary} ->
			binary_to_term(TxIdBinary)
	end.

read_data_by_addr(Addr) ->
	case ar_kv:get(address_data_db, Addr) of
		not_found ->
			[];
		{ok, TxIdBinary} ->
			binary_to_term(TxIdBinary)
	end.

update_reward_history(B) ->
	case B#block.height >= ar_fork:height_2_6() of
		true ->
			HashRate = ar_difficulty:get_hash_rate(B#block.diff),
			Addr = B#block.reward_addr,
			Bin = term_to_binary({Addr, HashRate, B#block.reward}),
			ar_kv:put(reward_history_db, B#block.indep_hash, Bin);
		false ->
			ok
	end.

write_full_block2(BShadow, TXs) ->
	case write_block(BShadow) of
		ok ->
			app_ipfs:maybe_ipfs_add_txs(TXs),
			ok;
		Error ->
			Error
	end.

read_block_from_file(Filename, Encoding) ->
	case read_file_raw(Filename) of
		{ok, Bin} ->
			case Encoding of
				json ->
					parse_block_json(Bin);
				binary ->
					parse_block_binary(Bin)
			end;
		{error, Reason} ->
			?LOG_WARNING([{event, error_reading_block},
					{error, io_lib:format("~p", [Reason])}]),
			unavailable
	end.

parse_block_json(JSON) ->
	case catch ar_serialize:json_decode(JSON) of
		{ok, JiffyStruct} ->
			case catch ar_serialize:json_struct_to_block(JiffyStruct) of
				B when is_record(B, block) ->
					B;
				Error ->
					?LOG_WARNING([{event, error_parsing_block_json},
							{error, io_lib:format("~p", [Error])}]),
					unavailable
			end;
		Error ->
			?LOG_WARNING([{event, error_parsing_block_json},
					{error, io_lib:format("~p", [Error])}]),
			unavailable
	end.

parse_block_binary(Bin) ->
	case catch ar_serialize:binary_to_block(Bin) of
		{ok, B} ->
			B;
		Error ->
			?LOG_WARNING([{event, error_parsing_block_bin},
					{error, io_lib:format("~p", [Error])}]),
			unavailable
	end.

filepath(PathComponents) ->
	{ok, Config} = application:get_env(chivesweave, config),
	to_string(filename:join([Config#config.data_dir | PathComponents])).

to_string(Bin) when is_binary(Bin) ->
	binary_to_list(Bin);
to_string(String) ->
	String.

%% @doc Ensure that all of the relevant storage directories exist.
ensure_directories(DataDir) ->
	%% Append "/" to every path so that filelib:ensure_dir/1 creates a directory
	%% if it does not exist.
	filelib:ensure_dir(filename:join(DataDir, ?TX_DIR) ++ "/"),
	filelib:ensure_dir(filename:join(DataDir, ?BLOCK_DIR) ++ "/"),
	filelib:ensure_dir(filename:join(DataDir, ?WALLET_LIST_DIR) ++ "/"),
	filelib:ensure_dir(filename:join(DataDir, ?HASH_LIST_DIR) ++ "/"),
	filelib:ensure_dir(filename:join(DataDir, ?STORAGE_MIGRATIONS_DIR) ++ "/"),
	filelib:ensure_dir(filename:join([DataDir, ?TX_DIR, "migrated_v1"]) ++ "/").

get_same_disk_storage_modules_total_size() ->
	{ok, Config} = application:get_env(chivesweave, config),
	DataDir = Config#config.data_dir,
	{ok, Info} = file:read_file_info(DataDir),
	Device = Info#file_info.major_device,
	get_same_disk_storage_modules_total_size(0, Config#config.storage_modules, DataDir,
			Device).

get_same_disk_storage_modules_total_size(TotalSize, [], _DataDir, _Device) ->
	TotalSize;
get_same_disk_storage_modules_total_size(TotalSize,
		[{Size, _Bucket, _Packing} = Module | StorageModules], DataDir, Device) ->
	Path = filename:join([DataDir, "storage_modules", ar_storage_module:id(Module)]),
	filelib:ensure_dir(Path ++ "/"),
	{ok, Info} = file:read_file_info(Path),
	TotalSize2 =
		case Info#file_info.major_device == Device of
			true ->
				TotalSize + Size;
			false ->
				TotalSize
		end,
	get_same_disk_storage_modules_total_size(TotalSize2, StorageModules, DataDir, Device).

tx_filepath(TX) ->
	filepath([?TX_DIR, tx_filename(TX)]).

tx_data_filepath(TX) when is_record(TX, tx) ->
	tx_data_filepath(TX#tx.id);
tx_data_filepath(ID) ->
	filepath([?TX_DIR, tx_data_filename(ID)]).

tx_filename(TX) when is_record(TX, tx) ->
	tx_filename(TX#tx.id);
tx_filename(TXID) when is_binary(TXID) ->
	iolist_to_binary([ar_util:encode(TXID), ".json"]).

tx_data_filename(TXID) ->
	iolist_to_binary([ar_util:encode(TXID), "_data.json"]).

block_index_filepath() ->
	filepath([?HASH_LIST_DIR, <<"last_block_index.json">>]).

block_index_and_reward_history_filepath() ->
	filepath([?HASH_LIST_DIR, <<"last_block_index_and_reward_history.bin">>]).

wallet_list_filepath(Hash) when is_binary(Hash) ->
	filepath([?WALLET_LIST_DIR, iolist_to_binary([ar_util:encode(Hash), ".json"])]).

write_file_atomic(Filename, Data) ->
	SwapFilename = Filename ++ ".swp",
	case file:open(SwapFilename, [write, raw]) of
		{ok, F} ->
			case file:write(F, Data) of
				ok ->
					case file:close(F) of
						ok ->
							file:rename(SwapFilename, Filename);
						Error ->
							Error
					end;
				Error ->
					Error
			end;
		Error ->
			Error
	end.

write_term(Name, Term) ->
	{ok, Config} = application:get_env(chivesweave, config),
	DataDir = Config#config.data_dir,
	write_term(DataDir, Name, Term, override).

write_term(Dir, Name, Term) when is_atom(Name) ->
	write_term(Dir, atom_to_list(Name), Term, override);
write_term(Dir, Name, Term) ->
	write_term(Dir, Name, Term, override).

write_term(Dir, Name, Term, Override) ->
	Filepath = filename:join(Dir, Name),
	case Override == do_not_override andalso filelib:is_file(Filepath) of
		true ->
			ok;
		false ->
			case write_file_atomic(Filepath, term_to_binary(Term)) of
				ok ->
					ok;
				{error, Reason} = Error ->
					?LOG_ERROR([{event, failed_to_write_term}, {name, Name},
							{reason, Reason}]),
					Error
			end
	end.

read_term(Name) ->
	{ok, Config} = application:get_env(chivesweave, config),
	DataDir = Config#config.data_dir,
	read_term(DataDir, Name).

read_term(Dir, Name) when is_atom(Name) ->
	read_term(Dir, atom_to_list(Name));
read_term(Dir, Name) ->
	case file:read_file(filename:join(Dir, Name)) of
		{ok, Binary} ->
			{ok, binary_to_term(Binary)};
		{error, enoent} ->
			not_found;
		{error, Reason} = Error ->
			?LOG_ERROR([{event, failed_to_read_term}, {name, Name}, {reason, Reason}]),
			Error
	end.

delete_term(Name) ->
	{ok, Config} = application:get_env(chivesweave, config),
	DataDir = Config#config.data_dir,
	file:delete(filename:join(DataDir, atom_to_list(Name))).

store_account_tree_update(Height, RootHash, Map) ->
	?LOG_INFO([{event, storing_account_tree_update}, {updated_key_count, map_size(Map)},
			{height, Height}, {root_hash, ar_util:encode(RootHash)}]),
	maps:map(
		fun(Key, Value) ->
			DBKey = term_to_binary(Key),
			case ar_kv:get(account_tree_db, DBKey) of
				not_found ->
					case ar_kv:put(account_tree_db, DBKey, term_to_binary(Value)) of
						ok ->
							ok;
						{error, Reason} ->
							?LOG_ERROR([{event, failed_to_store_account_tree_key},
									{key_hash, ar_util:encode(element(1, Key))},
									{key_prefix, case element(2, Key) of root -> root;
											Prefix -> ar_util:encode(Prefix) end},
									{height, Height},
									{root_hash, ar_util:encode(RootHash)},
									{reason, io_lib:format("~p", [Reason])}])
					end;
				{ok, _} ->
					ok;
				{error, Reason} ->
					?LOG_ERROR([{event, failed_to_read_account_tree_key},
							{key_hash, ar_util:encode(element(1, Key))},
							{key_prefix, case element(2, Key) of root -> root;
									Prefix -> ar_util:encode(Prefix) end},
							{height, Height},
							{root_hash, ar_util:encode(RootHash)},
							{reason, io_lib:format("~p", [Reason])}])
			end
		end,
		Map
	),
	?LOG_INFO([{event, stored_account_tree}]).

%% @doc Test block storage.
store_and_retrieve_block_test_() ->
	{timeout, 60, fun test_store_and_retrieve_block/0}.

test_store_and_retrieve_block() ->
	[B0] = ar_weave:init([]),
	ar_test_node:start(B0),
	TXIDs = [TX#tx.id || TX <- B0#block.txs],
	FetchedB0 = read_block(B0#block.indep_hash),
	FetchedB01 = FetchedB0#block{ txs = [tx_id(TX) || TX <- FetchedB0#block.txs] },
	FetchedB02 = read_block(B0#block.height, [{B0#block.indep_hash, B0#block.weave_size,
			B0#block.tx_root}]),
	FetchedB03 = FetchedB02#block{ txs = [tx_id(TX) || TX <- FetchedB02#block.txs] },
	?assertEqual(B0#block{ size_tagged_txs = unset, txs = TXIDs, reward_history = [],
			account_tree = undefined }, FetchedB01),
	?assertEqual(B0#block{ size_tagged_txs = unset, txs = TXIDs, reward_history = [],
			account_tree = undefined }, FetchedB03),
	ar_node:mine(),
	ar_test_node:wait_until_height(1),
	ar_node:mine(),
	BI1 = ar_test_node:wait_until_height(2),
	[{_, BlockCount}] = ets:lookup(ar_header_sync, synced_blocks),
	ar_util:do_until(
		fun() ->
			3 == BlockCount
		end,
		100,
		2000
	),
	BH1 = element(1, hd(BI1)),
	?assertMatch(#block{ height = 2, indep_hash = BH1 }, read_block(BH1)),
	?assertMatch(#block{ height = 2, indep_hash = BH1 }, read_block(2, BI1)).

tx_id(#tx{ id = TXID }) ->
	TXID;
tx_id(TXID) ->
	TXID.

store_and_retrieve_block_block_index_test() ->
	RandomEntry =
		fun() ->
			{crypto:strong_rand_bytes(48), rand:uniform(10000),
					crypto:strong_rand_bytes(32)}
		end,
	BI = [RandomEntry() || _ <- lists:seq(1, 100)],
	write_block_index(BI),
	ReadBI = read_block_index(),
	?assertEqual(BI, ReadBI).

store_and_retrieve_wallet_list_test_() ->
	{timeout, 20, fun test_store_and_retrieve_wallet_list/0}.

test_store_and_retrieve_wallet_list() ->
	[B0] = ar_weave:init(),
	[TX] = B0#block.txs,
	Addr = ar_wallet:to_address(TX#tx.owner, {?RSA_SIGN_ALG, 65537}),
	write_block(B0),
	ExpectedWL = ar_patricia_tree:from_proplist([{Addr, {0, TX#tx.id}}]),
	WalletListHash = write_wallet_list(0, ExpectedWL),
	{ok, ActualWL} = read_wallet_list(WalletListHash),
	assert_wallet_trees_equal(ExpectedWL, ActualWL).

assert_wallet_trees_equal(Expected, Actual) ->
	?assertEqual(
		ar_patricia_tree:foldr(fun(K, V, Acc) -> [{K, V} | Acc] end, [], Expected),
		ar_patricia_tree:foldr(fun(K, V, Acc) -> [{K, V} | Acc] end, [], Actual)
	).

read_wallet_list_chunks_test() ->
	TestCases = [
		[random_wallet()], % < chunk size
		[random_wallet() || _ <- lists:seq(1, ?WALLET_LIST_CHUNK_SIZE)], % == chunk size
		[random_wallet() || _ <- lists:seq(1, ?WALLET_LIST_CHUNK_SIZE + 1)], % > chunk size
		[random_wallet() || _ <- lists:seq(1, 10 * ?WALLET_LIST_CHUNK_SIZE)],
		[random_wallet() || _ <- lists:seq(1, 10 * ?WALLET_LIST_CHUNK_SIZE + 1)]
	],
	lists:foreach(
		fun(TestCase) ->
			Tree = ar_patricia_tree:from_proplist(TestCase),
			RootHash = write_wallet_list(0, Tree),
			{ok, ReadTree} = read_wallet_list(RootHash),
			assert_wallet_trees_equal(Tree, ReadTree)
		end,
		TestCases
	).

random_wallet() ->
	{crypto:strong_rand_bytes(32), {rand:uniform(1000000000), crypto:strong_rand_bytes(32)}}.
