class AddContextTokensToChannelWeixins < ActiveRecord::Migration[7.1]
  def up
    return unless table_exists?(:channel_weixins)
    return if column_exists?(:channel_weixins, :context_tokens)

    add_column :channel_weixins, :context_tokens, :jsonb, null: false, default: {}
  end

  def down
    return unless table_exists?(:channel_weixins)
    return unless column_exists?(:channel_weixins, :context_tokens)

    remove_column :channel_weixins, :context_tokens
  end
end
