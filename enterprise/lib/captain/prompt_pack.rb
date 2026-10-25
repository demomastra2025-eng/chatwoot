# frozen_string_literal: true

# Applies the prompt pack of one clinic and rolls it back (rake onelink:captain:apply_prompt_pack). A pack is a prompts-v2 JSON
# file, of the shape that Captain::PromptsV2Import reads:
#
#   { "account_id": 43,
#     "shared_block": "<the clinic block: accounts.internal_attributes['captain_clinic_context'], Account#captain_clinic_context>",
#     "assistants": [{ "id": 77,
#                      "description": "<the agent prompt: captain_assistants.description>",
#                      "routing_description": "<the routing competence card: captain_assistants.routing_description>" }, ...] }
#
# Every text of a pack has its home above, and a file with any other key is refused: a draft field without a home never passes.
#
# apply_file(path) and restore(backup_path) make a dry run unless apply: true.
# - A dry run writes nothing. It names the file with its SHA-256 and prints, for the clinic block and for the prompt and the card
#   of every listed agent, whether the text changes and its length in characters, stored and wanted; verbose: true adds a unified
#   diff of every changed text. When anything would change it ends with the digest of the change: of every stored text and every
#   wanted one, so it pins both the file and the database as they were reviewed.
# - apply: true needs confirm: that digest. Under row locks and in one transaction it prints the same and computes the change
#   again. When nothing changes it writes nothing, not even a backup: a second run is a no-op. Otherwise it is Refused unless the
#   digest of the change is confirm (the file or a stored text changed since the dry run), then first writes a JSON backup of the
#   stored clinic block and of the stored prompt and card of every listed agent (Captain::PromptPackBackup, in backup_dir), then
#   the changed texts: all of it or nothing. What was written and the backup are printed after the commit.
# - A pack is applied only by a build that has the decision router (ROUTER_CLASS): its cards and prompts are written for the router,
#   and the handoff path before it cuts a card to 120 characters. A dry run works anywhere and says so.
# - restore takes such a backup and writes its texts back the same way (a dry run, then apply: true with its digest, which backs
#   the current texts up first). It works on any build.
#
# Nothing else is written: not the agents of the account that the file does not list, nor any other attribute of an agent or of
# the account. The agents are saved with save!, so their validations hold. The account is written with update_columns on
# internal_attributes alone, because its save would also normalize unrelated settings; the clinic block is checked with the rules
# of Account#captain_clinic_context first, and the entry that the save would add to the audit log of the account
# (Enterprise::Audit::Account) is added by hand, in the same transaction.
#
# Refused is raised, with nothing written, when the file is not of its shape, the account does not exist, an id is not an agent of
# that account, a text would not be saved as it is (the rules of Account#captain_clinic_context, the validations of
# Captain::Assistant), the save of an agent would change more than its prompt and card (legacy rules or legacy settings that the
# callbacks of Captain::Assistant merge or drop), apply: true comes without confirm or with another digest, or a pack is applied
# by a build without the router.
class Captain::PromptPack
  Refused = Class.new(StandardError)

  # The written texts of an agent and what the output calls them
  ASSISTANT_TEXTS = { 'description' => 'prompt', 'routing_description' => 'card' }.freeze
  # Part of every digest: a digest made by another version of this code never matches
  DIGEST_VERSION = 'onelink-prompt-pack-1'
  # The digest is the first 16 hex characters of a SHA-256, as for captain:router_prompts:migrate CONFIRM
  DIGEST_LENGTH = 16
  # The router that reads the cards of a pack; a build without it applies no pack
  ROUTER_CLASS = 'Captain::Runtime::DecisionRouter'
  # Who wrote the clinic block, in the audit log of the account
  AUDIT_USERNAME = 'rake onelink:captain:apply_prompt_pack'

  # The texts wanted for one account: clinic_context a String, assistants [{ 'id', 'description', 'routing_description' }], and
  # where they come from
  Target = Data.define(:account_id, :clinic_context, :assistants, :source)
  # The account and its listed agents (locked on apply) with the wanted texts assigned to the agents
  Plan = Data.define(:account, :stored_context, :wanted_context, :assistants)

  # Whether this build has the decision router
  def self.router_live?
    ROUTER_CLASS.safe_constantize.present?
  end

  def initialize(out: $stdout, backup_dir: Rails.root.join('tmp'), verbose: false)
    @out = out
    @backup_dir = backup_dir.to_s
    @verbose = verbose
  end

  # Applies a pack file. Returns the path of the backup written, or nil (a dry run, or nothing to change).
  def apply_file(path, apply: false, confirm: nil)
    raise Refused, 'a pack file is required' if path.blank?

    file = Captain::PromptsV2Import.new(path: path)
    payload = file.payload
    refuse_without_router! if apply
    target = Target.new(account_id: payload['account_id'], clinic_context: payload['shared_block'],
                        assistants: payload['assistants'], source: "pack #{path} (sha256 #{file.sha256})")
    run(target, apply: apply, confirm: confirm, pack: true)
  rescue Captain::PromptsV2Import::Refused => e
    raise Refused, e.message
  end

  # Writes back the texts of a backup made by an apply. Returns the path of the backup of the current texts, or nil.
  def restore(path, apply: false, confirm: nil)
    run(Captain::PromptPackBackup.read(path), apply: apply, confirm: confirm, pack: false)
  end

  private

  def refuse_without_router!
    return if self.class.router_live?

    raise Refused, "this build has no decision router (#{ROUTER_CLASS}): the prompts and cards of a pack are written for the router, " \
                   'and the handoff path before it cuts a card to 120 characters; apply the pack once the router is deployed'
  end

  def run(target, apply:, confirm:, pack:)
    confirm = confirm.to_s.strip
    raise Refused, 'APPLY=1 needs CONFIRM=<the digest that the dry run printed>: run the dry run first and review it' if apply && confirm.empty?

    account = Account.find_by(id: target.account_id)
    raise Refused, "account #{target.account_id} does not exist" if account.nil?

    @out.puts "Prompt texts of account #{account.id} «#{account.name}» from the #{target.source}: " \
              "#{apply ? 'writing in one transaction' : 'dry run, nothing is written'}."
    apply ? apply!(account, target, confirm) : dry_run(account, target, pack: pack)
  end

  def dry_run(account, target, pack:)
    plan = plan!(account, target, lock: false)
    unless changed?(plan)
      @out.puts "Nothing to write, every text is stored already (#{summary(plan)})."
      return
    end

    digest = digest(plan)
    @out.puts "Would write: #{summary(plan)}.", "Digest of this change: #{digest}. To write exactly this: APPLY=1 CONFIRM=#{digest}"
    @out.puts "This build has no decision router (#{ROUTER_CLASS}), so it refuses APPLY=1 of a pack." if pack && !self.class.router_live?
    nil
  end

  def apply!(account, target, confirm)
    backup, summary = ActiveRecord::Base.transaction do
      account.lock!
      plan = plan!(account, target, lock: true)
      next [nil, summary(plan)] unless changed?(plan)

      check_confirm!(plan, confirm)
      summary = summary(plan)
      backup = Captain::PromptPackBackup.write(plan, dir: @backup_dir, source: target.source)
      write!(plan)
      [backup, summary]
    end
    report_apply(backup, summary)
  end

  def check_confirm!(plan, confirm)
    return if confirm == digest(plan)

    raise Refused, "CONFIRM=#{confirm} is not the digest of this change: the file or a stored text changed after that dry run. " \
                   'Run the dry run again, review it and pass the digest that it prints'
  end

  # Printed after the commit, so it never claims a write that was rolled back
  def report_apply(backup, summary)
    if backup.nil?
      @out.puts "Nothing written, every text is stored already (#{summary}); no backup was made."
    else
      @out.puts "Written: #{summary}.", "Backup of the stored texts: #{backup}",
                "Roll back with: RESTORE=#{backup} (a dry run), then the same with APPLY=1 CONFIRM=<the digest it prints>"
    end
    backup
  end

  # Assigns the wanted texts to the listed agents, prints what changes and returns the plan; raises Refused, after printing, when a
  # text would not be saved as it is.
  def plan!(account, target, lock:)
    assistants = listed_assistants(account, target.assistants, lock: lock)
    plan = Plan.new(account: account, stored_context: account.captain_clinic_context,
                    wanted_context: Account.normalize_captain_clinic_context(target.clinic_context), assistants: assistants)
    print_text('clinic block', plan.stored_context, plan.wanted_context)
    assistants.each { |assistant| print_assistant(assistant) }

    problems = context_problems(plan) + assistants.flat_map { |assistant| assistant_problems(assistant, target) }
    raise Refused, problems.join("\n") if problems.any?

    plan
  end

  # The listed agents of the account, in the order of the file, with the wanted texts assigned and validated. Refused when an id
  # is not an agent of this account.
  def listed_assistants(account, entries, lock:)
    ids = entries.pluck('id')
    scope = Captain::Assistant.where(account_id: account.id, id: ids)
    records = (lock ? scope.lock : scope).index_by(&:id)
    foreign = ids - records.keys
    raise Refused, "not agents of account #{account.id}: #{describe_foreign(foreign)}" if foreign.any?

    entries.map do |entry|
      records.fetch(entry['id']).tap do |assistant|
        assistant.assign_attributes(entry.slice(*ASSISTANT_TEXTS.keys))
        assistant.valid?
      end
    end
  end

  def describe_foreign(ids)
    owners = Captain::Assistant.where(id: ids).pluck(:id, :account_id).to_h
    ids.map { |id| owners.key?(id) ? "#{id} (account #{owners[id]})" : "#{id} (does not exist)" }.join(', ')
  end

  def print_assistant(assistant)
    ASSISTANT_TEXTS.each do |attribute, name|
      print_text("assistant #{assistant.id} «#{assistant.name}» #{name} (#{attribute})",
                 assistant.attribute_in_database(attribute), assistant[attribute])
    end
  end

  def print_text(label, stored, wanted)
    if stored == wanted
      @out.puts "= #{label}: unchanged, #{stored.to_s.length} chars"
      return
    end

    @out.puts "~ #{label}: #{stored.to_s.length} -> #{wanted.to_s.length} chars"
    @out.print Captain::TextDiff.unified(stored, wanted, from: "#{label} (stored)", to: "#{label} (wanted)") if @verbose
  end

  def context_problems(plan)
    return [] if plan.stored_context == plan.wanted_context

    errors = ActiveModel::Errors.new(plan.account)
    Account.captain_clinic_context_errors(plan.wanted_context).each do |error, options|
      errors.add(:captain_clinic_context, error, **options)
    end
    errors.full_messages.map { |message| "account #{plan.account.id}: #{message}" }
  end

  # The validation errors of the agent, and whatever else its save would change: the stored texts must be the wanted ones, and
  # nothing else of the agent may change.
  def assistant_problems(assistant, target)
    problems = assistant.errors.full_messages.map { |message| "assistant #{assistant.id}: #{message}" }
    wanted = target.assistants.find { |entry| entry['id'] == assistant.id }['description']
    extra = assistant.changed - ASSISTANT_TEXTS.keys
    extra.unshift('description (legacy rules appended to the prompt)') if assistant.description != wanted
    return problems if extra.empty?

    problems << "assistant #{assistant.id}: its save would change more than the prompt and the card (#{extra.join(', ')}): legacy " \
                'rules or settings that every save of an agent merges or drops; save the agent once in the dashboard, then run this again'
  end

  def changed?(plan)
    plan.stored_context != plan.wanted_context || plan.assistants.any?(&:changed?)
  end

  # Every stored text and every wanted one, of the clinic block and of the listed agents in the order of the file
  def digest(plan)
    agents = plan.assistants.map do |assistant|
      [assistant.id, *ASSISTANT_TEXTS.keys.flat_map { |attribute| [assistant.attribute_in_database(attribute), assistant[attribute]] }]
    end
    payload = [DIGEST_VERSION, plan.account.id, plan.stored_context, plan.wanted_context, agents]
    Digest::SHA256.hexdigest(JSON.generate(payload))[0, DIGEST_LENGTH]
  end

  def write!(plan)
    write_context!(plan) if plan.stored_context != plan.wanted_context
    plan.assistants.select(&:changed?).each(&:save!)
  end

  # Only the key of the clinic block changes in internal_attributes, and no other column of the account
  def write_context!(plan)
    account = plan.account
    stored = account.internal_attributes.deep_dup
    account.captain_clinic_context = plan.wanted_context
    account.update_columns(internal_attributes: account.internal_attributes, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    audit_context!(account, stored)
  end

  # The entry of the audit log that a save of the account would add (Enterprise::Audit::Account) and update_columns skips. The
  # writer is this task: a name, not a user, so the comment is 'system' (SuperAdmin::PlatformAudit).
  def audit_context!(account, stored)
    return unless account.class.respond_to?(:auditing_enabled) && account.class.auditing_enabled

    account.audits.create!(action: 'update', audited_changes: { 'internal_attributes' => [stored, account.internal_attributes] },
                           user: AUDIT_USERNAME, comment: SuperAdmin::PlatformAudit::SYSTEM_COMMENT)
  end

  def summary(plan)
    changed = plan.assistants.select(&:changed?).map(&:id)
    "clinic block #{plan.stored_context == plan.wanted_context ? 'unchanged' : 'changed'}; agents changed: " \
      "#{changed.any? ? changed.join(', ') : 'none'} (listed: #{plan.assistants.map(&:id).join(', ')})"
  end
end
