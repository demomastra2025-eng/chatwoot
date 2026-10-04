module Api::V1::Accounts::Crm::Concerns::TaskTimeBucketNormalizer
  private

  def normalize_time_bucket_as_of!
    return if params[:time_bucket].blank?

    timezone = ::Crm::WorkspaceTimezone.resolve(Current.account)
    parsed_as_of = Time.zone.parse(params[:as_of].to_s) if params[:as_of].present?
    params[:as_of] = (parsed_as_of || Time.current).in_time_zone(timezone).iso8601(6)
  rescue ArgumentError, TypeError
    params[:as_of] = Time.current.in_time_zone(timezone).iso8601(6)
  end
end
