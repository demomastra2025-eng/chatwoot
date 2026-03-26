class Crm::Timelines::BaseService
  DEFAULT_LIMIT = 20
  MAX_LIMIT = 100

  private

  attr_reader :account, :actor, :params

  def initialize(account:, actor:, params: {})
    @account = account
    @actor = actor
    @params = params.to_h.deep_symbolize_keys
  end

  def before_time
    return @before_time if defined?(@before_time)
    return @before_time = nil if params[:before].blank?

    @before_time = Time.zone.parse(params[:before].to_s)
    raise ArgumentError, 'before must be a valid datetime' if @before_time.blank?

    @before_time
  end

  def limit
    @limit ||= begin
      value = params[:limit].presence || DEFAULT_LIMIT
      value.to_i.clamp(1, MAX_LIMIT)
    end
  end

  def timeline_response(items)
    ordered_items = items.sort_by do |item|
      [
        item.fetch(:occurred_at),
        item.fetch(:sort_id)
      ]
    end.reverse.first(limit)

    {
      items: ordered_items.map { |item| item.except(:sort_id) },
      meta: {
        count: ordered_items.size,
        next_cursor: ordered_items.last&.dig(:occurred_at)&.iso8601
      }
    }
  end
end
