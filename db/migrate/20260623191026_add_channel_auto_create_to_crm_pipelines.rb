class AddChannelAutoCreateToCrmPipelines < ActiveRecord::Migration[7.1]
  def change
    add_column :crm_pipelines, :auto_create_deal_on_channel_contact, :boolean, null: false, default: false
  end
end
