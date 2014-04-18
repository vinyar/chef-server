-module(mover_reindex_dry_run_prep_migration_callback).

-export([
	  migration_init/0,
         migration_type/0,
         supervisor/0,
         migration_start_worker_args/2,
         error_halts_migration/0,
         reconfigure_object/2,
	  migration_action/2,
	  next_object/0,
         migration_complete/0
         ]).

-include("mover.hrl").
-include_lib("moser/include/moser.hrl").
-include_lib("eunit/include/eunit.hrl").

migration_init() ->
    % make sure we aren't in dry_run because otherwise
    % we can't set redis value
    false = envy:get(mover, dry_run, boolean),

    % initialize a transient queue with all orgs, we will fail in migration_action
    % if the org has already been phase_2 migrated as it has an entry in the state table
    AllOrgs = moser_acct_processor:all_orgs(moser_acct_processor:open_account()),
    OrgNames = [ OrgName || #org_info{org_name=OrgName} <- AllOrgs],
    mover_transient_migration_queue:initialize_queue(?MODULE, OrgNames).

migration_start_worker_args(Object, AcctInfo) ->
    [Object, AcctInfo].

migration_action(OrgName, AcctInfo) ->
    OrgInfo = moser_acct_processor:expand_org_info(#org_info{org_name = OrgName, account_info = AcctInfo}),
    OrgId = OrgInfo#org_info.org_id,

    case moser_state_tracker:insert_one_org(OrgInfo, mover_reindex_dry_run_migration_callback:migration_type()) of
	% org did not have phase_2_migration set in state table,
        % darklaunch it and set phase_2_migration to holding
	ok ->
	    ok;
	% org already exited for phase_2_migration in state table, do nothing
	{error, {error, error, <<"23505">>, _Msg, _Detail}} ->
	    lager:warning([{org_name,OrgName}, {org_id, OrgId}], "org already exists, forcing to holding"),
    	    moser_state_tracker:force_org_to_state(OrgName, mover_reindex_dry_run_migration_callback:migration_type(), <<"holding">>),
            mover_reindex_dry_run_revert_migration_callback:reconfigure_object(OrgName),
	    ok;
	{error, Reason} ->
            lager:error([{org_name,OrgName}, {org_id, OrgId}],
                        "stopping - failed to capture state because: ~p", [Reason]),
            Reason
    end.

next_object() ->
    mover_transient_migration_queue:next(?MODULE).

migration_type() ->
    <<"reindex_migration_prep">>.

supervisor() ->
    mover_transient_worker_sup.

error_halts_migration() ->
    true.

reconfigure_object(_ObjectId, _AcctInfo) ->
    no_op.

migration_complete() ->
    mover_org_darklaunch:enable_solr4().
