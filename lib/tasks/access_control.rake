namespace :access_control do
  desc 'Preview or apply AccessRole presets and legacy AccountUser assignments (set APPLY=1 to write)'
  task bootstrap_roles: :environment do
    apply = ENV['APPLY'] == '1'
    results = Account.find_each.map do |account|
      result = AccessControl::LegacyRoleAssigner.call(account: account, apply: apply)
      {
        account_id: result.account_id,
        apply: result.apply,
        counts: result.counts,
        entries: result.entries.map(&:to_h)
      }
    end

    puts JSON.pretty_generate(results)
  end
end
