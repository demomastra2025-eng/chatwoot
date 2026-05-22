class HardenLlmEvalRunsForQueuedEvals < ActiveRecord::Migration[7.0]
  ACTIVE_LIVE_INDEX = 'index_llm_eval_runs_one_active_live_per_account'.freeze

  def up
    change_column_default :llm_eval_runs, :mode, from: 'live_model', to: 'evals'
    execute <<~SQL.squish
      UPDATE llm_eval_runs
      SET mode = 'evals'
      WHERE mode = 'live_model'
    SQL

    add_index :llm_eval_runs,
              [:account_id],
              unique: true,
              where: "status IN ('queued', 'running') AND metadata ->> 'queued_llm_model_run' = 'true'",
              name: ACTIVE_LIVE_INDEX,
              if_not_exists: true
  end

  def down
    remove_index :llm_eval_runs, name: ACTIVE_LIVE_INDEX, if_exists: true
    change_column_default :llm_eval_runs, :mode, from: 'evals', to: 'live_model'
  end
end
