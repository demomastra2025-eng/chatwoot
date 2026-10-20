# frozen_string_literal: true

# Blocking an account («Заблокировать») and unblocking it («Разблокировать») from the card of the account. A blocked account
# does not serve its operators and the widgets on its sites until it is unblocked; nothing is deleted. Both leave an entry of
# the audit log of the account (`suspend_account` with the reason and the comment, `activate_account`), the same entries the
# block / unblock of many accounts at once leaves (SuperAdmin::BulkAccounts), so the card can say when, by whom and why.
#
#   blocking = SuperAdmin::AccountBlocking.new(account: account, actor: current_super_admin, request: request)
#   blocking.suspend(reason: 'non_payment', note: 'счёт за октябрь') # => :suspended, or :already_suspended
#   blocking.activate                                                  # => :activated, or :already_active
#   SuperAdmin::AccountBlocking.last_block(account)                    # => Block(at:, by:, reason:, note:), or nil
class SuperAdmin::AccountBlocking
  SUSPEND_ACTION = 'suspend_account'
  ACTIVATE_ACTION = 'activate_account'
  # What the list of reasons offers; a reason nobody sent is stored as nil («не указана»)
  REASONS = %w[non_payment client_request other].freeze
  NOTE_LIMIT = 300
  # at: when the account was blocked; by: the name of the super admin (nil for a block with no known person);
  # reason: one of REASONS or nil; note: the free comment or nil
  Block = Struct.new(:at, :by, :reason, :note, keyword_init: true)

  def initialize(account:, actor: nil, request: nil)
    @account = account
    @actor = actor
    @request = request
  end

  # The reason is one of REASONS (anything else counts as none), the note is cut to NOTE_LIMIT characters
  def suspend(reason: nil, note: nil)
    change('suspended', :suspended, :already_suspended, SUSPEND_ACTION, reason: normalize_reason(reason), note: normalize_note(note))
  end

  def activate
    change('active', :activated, :already_active, ACTIVATE_ACTION)
  end

  # The newest block of an account that is blocked now; nil for an active account, and for a blocked one that no entry of the
  # audit log explains (it was blocked before the entries existed, or from the console)
  def self.last_block(account)
    return unless account.suspended?

    audit = Audited::Audit.where(auditable_type: 'Account', auditable_id: account.id, action: [SUSPEND_ACTION, ACTIVATE_ACTION])
                          .order(id: :desc).includes(:user).first
    return unless audit&.action == SUSPEND_ACTION

    changes = audit.audited_changes.to_h
    Block.new(at: audit.created_at, by: person(audit), reason: changes['reason'].presence, note: changes['note'].presence)
  end

  def self.person(audit)
    user = audit.user
    return user.name.presence || user.email if user.respond_to?(:name)

    audit.username.presence
  end
  private_class_method :person

  private

  # Moves the status under the lock of the account row, so two operators pressing the button together change it once
  def change(status, done, already, action, **extra)
    outcome = already
    @account.with_lock do
      next if @account.status == status

      source = @account.status
      # The entry below says who and why; the automatic «Изменение» entry would only repeat it (the bulk block does the same)
      Account.without_auditing { @account.update!(status: status) }
      SuperAdmin::AccountAudit.record(
        account: @account, actor: @actor, action: action, request: @request,
        changes: { 'status' => [source, status] }.merge(extra.compact)
      )
      outcome = done
    end
    outcome
  end

  def normalize_reason(reason)
    reason.to_s if REASONS.include?(reason.to_s)
  end

  def normalize_note(note)
    note.to_s.squish.truncate(NOTE_LIMIT).presence
  end
end
