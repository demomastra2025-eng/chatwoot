module Enterprise::DeleteObjectJob
  private

  def heavy_associations
    super.merge(
      SlaPolicy => %i[applied_slas]
    ).freeze
  end

  def process_post_deletion_tasks(object, user, ip, deletion_context = {})
    super
    create_audit_entry(object, user, ip, deletion_context)
  end

  def create_audit_entry(object, user, ip, deletion_context = {})
    return unless %w[Inbox Conversation SlaPolicy].include?(object.class.to_s) && user.present?

    audited_changes = object.attributes
    if object.is_a?(Inbox) && deletion_context[:channel_medium].present?
      audited_changes = audited_changes.merge('medium' => deletion_context[:channel_medium])
    end

    Enterprise::AuditLog.create(
      auditable: object,
      audited_changes: audited_changes,
      action: 'destroy',
      user: user,
      associated: object.account,
      remote_address: ip
    )
  end
end
