# The state of the server: the platform build, PostgreSQL and Redis. Every row is
# `{ label:, value:, tone: }`; the tone (:good, :bad or nil) paints a badge, a row
# without a tone is a plain value. All texts come from `super_admin.instance_status`.
class SuperAdmin::InstanceStatusesController < SuperAdmin::ApplicationController
  def show
    @sections = [
      { key: :platform, rows: platform_rows },
      { key: :postgres, rows: [postgres_row] },
      { key: :redis, rows: redis_rows }
    ]
  end

  private

  def platform_rows
    [
      row(:version, SuperAdmin::BuildInfo.version),
      row(:git_sha, SuperAdmin::BuildInfo.build),
      migrations_row
    ]
  end

  def migrations_row
    pending = ActiveRecord::Base.connection_pool.migration_context.needs_migration?
    row(:migrations, status_word(pending ? :pending : :applied), pending ? :bad : :good)
  end

  def postgres_row
    alive = ActiveRecord::Base.connection.active?
    row(:connection, status_word(alive ? :available : :unavailable), alive ? :good : :bad)
  end

  def redis_rows
    redis = Redis.new(Redis::Config.app)
    return [row(:connection, status_word(:unavailable), :bad)] unless redis.ping == 'PONG'

    info = redis.info
    [row(:connection, status_word(:available), :good), *redis_server_rows(info), *redis_memory_rows(info)]
  rescue Redis::CannotConnectError
    [row(:connection, status_word(:unavailable), :bad)]
  end

  def redis_server_rows(info)
    [
      row(:redis_version, info['redis_version']),
      row(:clients, SuperAdmin::DisplayHelper.format_number(info['connected_clients'].to_i)),
      row(:max_clients, SuperAdmin::DisplayHelper.format_number(info['maxclients'].to_i))
    ]
  end

  def redis_memory_rows(info)
    [
      row(:memory_used, memory(info['used_memory'])),
      row(:memory_peak, memory(info['used_memory_peak'])),
      row(:memory_total, memory(info['total_system_memory'])),
      row(:max_memory, info['maxmemory'].to_i.zero? ? I18n.t('super_admin.instance_status.unlimited') : memory(info['maxmemory'])),
      row(:eviction_policy, info['maxmemory_policy'])
    ]
  end

  def memory(bytes)
    SuperAdmin::DisplayHelper.format_bytes(bytes.to_i)
  end

  def status_word(state)
    I18n.t("super_admin.instance_status.states.#{state}")
  end

  def row(key, value, tone = nil)
    { label: I18n.t("super_admin.instance_status.rows.#{key}"), value: value, tone: tone }
  end
end
