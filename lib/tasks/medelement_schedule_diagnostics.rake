namespace :medelement do
  desc 'Print account-scoped MedElement schedule snapshot counts per hook'
  task schedule_diagnostics: :environment do
    Integrations::Hook.where(app_id: 'medelement').find_each do |hook|
      scope = Integrations::Medelement::ScheduleDay.where(account_id: hook.account_id, hook_id: hook.id)
      resource_ids = scope.distinct.pluck(:resource_id)
      rules = Scheduling::WorkRule.active.where(account_id: hook.account_id, resource_id: resource_ids)
                                  .group_by(&:resource_id)
      differing_days = 0
      scope.where(status: %w[confirmed empty_confirmed]).find_each do |day|
        provider = day.windows.map { |window| [window['start_minute'], window['end_minute']] }.sort
        template = rules.fetch(day.resource_id, []).select { |rule| rule.weekday == day.date.wday }
                        .map { |rule| [rule.start_minute, rule.end_minute] }.sort
        differing_days += 1 if provider != template
      end
      puts({
        account_id: hook.account_id,
        hook_id: hook.id,
        doctors_with_snapshot: scope.where.not(source_checked_at: nil).distinct.count(:resource_id),
        differing_days: differing_days,
        oldest_source_checked_at: scope.minimum(:source_checked_at)&.iso8601,
        unverified_days: scope.where(status: 'unverified').count
      }.to_json)
    end
  end
end
