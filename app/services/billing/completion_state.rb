# frozen_string_literal: true

require 'digest'

# Checkpoints belong to their existing financial row. A provider claim is deliberately
# not an exactly-once guarantee: an unknown outcome requires reconciliation by a human.
class Billing::CompletionState # rubocop:disable Metrics/ClassLength
  KEY = 'completion_v1'
  CLAIM_TTL = 5.minutes
  FINAL_STATES = %w[completed skipped needs_review].freeze

  def self.metadata(scope:, context:, steps:)
    digest = Digest::SHA256.hexdigest(JSON.generate(context))
    {
      KEY => {
        'managed' => true, 'context' => context,
        'steps' => steps.index_with do |step|
          { 'operation_key' => "#{scope}:#{step}", 'input_digest' => digest, 'state' => 'pending' }
        end
      }
    }
  end

  def self.invoice_metadata(account:, profile:, invoice_number:, notify:)
    context = invoice_context(account, profile).merge('notify' => notify)
    result = metadata(scope: "invoice:#{invoice_number}", context: context,
                      steps: %w[pdf bcc_invoice payment_url invoice_issued eavr esf])
    result[KEY]['steps']['invoice_issued']['state'] = 'skipped' unless notify
    result
  end

  def self.invoice_context(account, profile)
    target_id = profile.billing_whatsapp_conversation_id
    allowed = [account.id, OwnerFinance::AccessPolicy.workspace_account_id].compact.uniq
    target = Conversation.where(account_id: allowed).find_by(id: target_id) if target_id
    {
      'account_id' => account.id,
      'target' => {
        'id' => target_id, 'account_id' => target&.account_id,
        'inbox_id' => target&.inbox_id, 'contact_id' => target&.contact_id
      },
      'document' => {
        'contract_number' => profile.effective_contract_number.presence || 'Оферта OneLink',
        'supplier_bin' => Billing::Config.bcc_supplier_bin, 'supplier_name' => Billing::Config.bcc_supplier_name,
        'supplier_iban' => Billing::Config.bcc_business_iban, 'supplier_bik' => Billing::Config.bcc_supplier_bik,
        'supplier_kbe' => Billing::Config.bcc_supplier_kbe
      }
    }
  end
  private_class_method :invoice_context

  def self.unfinished(scope)
    scope.where("metadata -> '#{KEY}' ->> 'managed' = 'true'")
         .where(<<~SQL.squish)
           EXISTS (SELECT 1 FROM jsonb_each(metadata -> '#{KEY}' -> 'steps') AS step
                   WHERE step.value ->> 'state' IN ('pending', 'running', 'blocked'))
         SQL
  end

  def initialize(record)
    @record = record
  end

  def managed? = @record.metadata.dig(KEY, 'managed') == true
  def context = @record.metadata.dig(KEY, 'context').to_h
  def step(name) = @record.metadata.dig(KEY, 'steps', name).to_h

  # The caller may hold earlier locks, but this helper never acquires a Contact,
  # Account or Profile lock after the financial row.
  def local!(name, guard: -> { true })
    @record.with_lock do
      next false unless prepare_step!(name)
      next false unless guard.call

      next completed_receipt?(name) if step(name)['state'] == 'completed'
      next false if FINAL_STATES.include?(step(name)['state'])

      receipt = yield
      next false unless receipt

      write!(name, 'completed', receipt: receipt)
      true
    end
  end

  def block!(name, reason)
    @record.with_lock do
      next false unless prepare_step!(name)
      next false if FINAL_STATES.include?(step(name)['state'])

      write!(name, 'blocked', reason: reason)
      false
    end
  end

  def hold!(name, reason)
    @record.with_lock do
      prepare_step!(name)
      write!(name, 'needs_review', reason: reason) unless step(name)['state'] == 'completed'
      false
    end
  end

  def claim!(name, configured:, irreversible: true)
    @record.with_lock do
      next nil unless prepare_step!(name)

      next nil unless claimable?(name, irreversible)
      next nil unless !block_given? || yield

      unless configured
        write!(name, 'blocked', reason: 'pending_configuration')
        next nil
      end

      token = SecureRandom.uuid
      write!(name, 'running', token: token, claimed_at: Time.current.iso8601)
      token
    end
  end

  def finish!(name, token, receipt:, attributes: {})
    @record.with_lock do
      next false unless owns_claim?(name, token)

      yield if block_given?
      @record.assign_attributes(attributes)
      write!(name, 'completed', receipt: receipt)
      true
    end
  end

  def fail!(name, token, error:, irreversible: true)
    @record.with_lock do
      next false unless owns_claim?(name, token)

      write!(name, irreversible ? 'needs_review' : 'pending', reason: error.class.name)
      false
    end
  end

  def external!(name, configured:, receipt_attribute:, attributes: {}, guard: -> { true })
    # Existing document IDs are concrete receipts, including legacy rows. They do
    # not grant permission to replay a different missing external operation.
    prepared = prepare_external!(name, configured, receipt_attribute)
    return prepared unless prepared.nil?

    raise 'Billing external IO requires a committed transaction' if ActiveRecord::Base.connection.open_transactions.positive?

    token = claim!(name, configured: configured, &guard)
    return false unless token

    result = yield
    receipt = result.fetch(:receipt).to_s.presence
    raise ArgumentError, 'Missing provider receipt' unless receipt

    finish!(name, token, receipt: { receipt_attribute.to_s => receipt },
                         attributes: attributes.merge(result.fetch(:attributes, {})).merge(receipt_attribute => receipt))
  rescue StandardError => e
    raise unless token

    fail!(name, token, error: e)
  end

  private

  def prepare_external!(name, configured, receipt_attribute)
    @record.reload
    return adopt_receipt!(name, receipt_attribute) if @record.public_send(receipt_attribute).present?
    return hold!(name, 'legacy_without_checkpoint') unless managed?
    return block!(name, 'pending_configuration') unless configured

    nil
  end

  def completed_receipt?(name)
    return true if step(name)['receipt'].present?

    write!(name, 'needs_review', reason: 'missing_completion_receipt')
    false
  end

  def claimable?(name, irreversible)
    current = step(name)
    return false if FINAL_STATES.include?(current['state'])
    return true unless current['state'] == 'running'
    return false if Time.iso8601(current.fetch('claimed_at')) > CLAIM_TTL.ago
    return true unless irreversible

    write!(name, 'needs_review', reason: 'stale_external_claim')
    false
  end

  def adopt_receipt!(name, receipt_attribute)
    @record.with_lock do
      receipt = @record.public_send(receipt_attribute)
      next nil if receipt.blank?

      prepare_step!(name)
      next true if step(name)['state'] == 'completed' && step(name)['receipt'].present?

      write!(name, 'completed', receipt: { 'existing_document_id' => receipt })
      true
    end
  end

  def owns_claim?(name, token)
    token.present? && step(name)['state'] == 'running' && step(name)['token'] == token
  end

  def prepare_step!(name)
    unless managed?
      meta = @record.metadata.deep_dup
      meta[KEY] ||= { 'managed' => false, 'steps' => {} }
      meta[KEY]['steps'][name] ||= { 'state' => 'needs_review', 'reason' => 'legacy_without_checkpoint' }
      @record.update!(metadata: meta)
      return false
    end
    return true if step(name).present?

    scope = @record.is_a?(Billing::Invoice) ? "invoice:#{@record.invoice_number}" : "event:#{@record.source}:#{@record.bank_reference_id}"
    digest = Digest::SHA256.hexdigest(JSON.generate(context))
    meta = @record.metadata.deep_dup
    meta[KEY]['steps'][name] = { 'operation_key' => "#{scope}:#{name}", 'input_digest' => digest, 'state' => 'pending' }
    @record.update!(metadata: meta)
    true
  end

  def write!(name, state, **details)
    meta = @record.metadata.deep_dup
    old = meta.fetch(KEY).fetch('steps').fetch(name)
    meta[KEY]['steps'][name] = old.except('token', 'claimed_at', 'reason').merge('state' => state).merge(details.stringify_keys)
    @record.update!(metadata: meta)
  end
end
