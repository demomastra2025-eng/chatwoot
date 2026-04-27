class NormalizeFonosterOperatorAgentAor < ActiveRecord::Migration[7.1]
  CURRENT_OPERATOR_AGENT_AOR = 'sip:1001@operator.cloud.vconsult.kz'.freeze
  STALE_OPERATOR_AGENT_AOR = 'sip:1001@company.example'.freeze

  def up
    update_routing_policies
    update_voice_channel_configs
  end

  def down
    # Data correction only. Do not restore the stale placeholder AOR.
  end

  private

  def update_routing_policies
    current_aor = connection.quote(CURRENT_OPERATOR_AGENT_AOR)
    stale_aor = connection.quote(STALE_OPERATOR_AGENT_AOR)

    execute <<~SQL.squish
      UPDATE telephony_routing_policies
      SET operator_agent_aor = #{current_aor}, updated_at = CURRENT_TIMESTAMP
      WHERE operator_agent_aor = #{stale_aor}
    SQL
  end

  def update_voice_channel_configs
    current_aor = connection.quote(CURRENT_OPERATOR_AGENT_AOR)
    stale_aor = connection.quote(STALE_OPERATOR_AGENT_AOR)

    execute <<~SQL.squish
      UPDATE channel_voice
      SET provider_config = jsonb_set(provider_config, '{operator_agent_aor}', to_jsonb(#{current_aor}::text), true),
          updated_at = CURRENT_TIMESTAMP
      WHERE provider = 'fonoster'
        AND provider_config ->> 'operator_agent_aor' = #{stale_aor}
    SQL
  end
end
