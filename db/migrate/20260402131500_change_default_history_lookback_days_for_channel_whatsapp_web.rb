class ChangeDefaultHistoryLookbackDaysForChannelWhatsappWeb < ActiveRecord::Migration[7.1]
  def up
    change_column_default :channel_whatsapp_web, :history_lookback_days, from: 365, to: 0
  end

  def down
    change_column_default :channel_whatsapp_web, :history_lookback_days, from: 0, to: 365
  end
end
