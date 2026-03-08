class RebrandDefaultWidgetAndPortalColors < ActiveRecord::Migration[7.1]
  LEGACY_BRAND_COLORS = %w[#1f93ff #1F93FF #2781F6].freeze
  NEW_BRAND_COLOR = '#1A1A1A'.freeze

  def up
    change_column_default :channel_web_widgets, :widget_color, from: '#1f93ff', to: NEW_BRAND_COLOR

    execute <<~SQL.squish
      UPDATE channel_web_widgets
      SET widget_color = '#{NEW_BRAND_COLOR}'
      WHERE widget_color IN ('#{LEGACY_BRAND_COLORS.join("','")}')
    SQL

    execute <<~SQL.squish
      UPDATE portals
      SET color = '#{NEW_BRAND_COLOR}'
      WHERE color IN ('#{LEGACY_BRAND_COLORS.join("','")}')
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Brand color backfill cannot be reversed safely'
  end
end
