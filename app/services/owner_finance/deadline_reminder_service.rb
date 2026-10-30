# frozen_string_literal: true

class OwnerFinance::DeadlineReminderService
  CATEGORY_LABELS = {
    'hosting' => 'Хостинг/Сервер',
    'client_domain' => 'Домен клиента',
    'own_domain' => 'Наш домен',
    'contract' => 'Договор',
    'personal' => 'Личный срок/ИП'
  }.freeze

  def initialize(reference_date: OwnerFinance.today_almaty)
    @reference_date = reference_date
  end

  def perform
    @owner = User.find_by(id: OwnerFinance::AccessPolicy.owner_user_id)
    @workspace_account = resolve_workspace_account(@owner)
    reminded = @workspace_account ? process_deadlines : []
    { reference_date: @reference_date.iso8601, reminded_count: reminded.size, items: reminded }
  end

  private

  def process_deadlines
    Crm::TaskCatalogs::Provisioner.new(account: @workspace_account).perform
    @todo_status = resolve_todo_status
    @task_type = resolve_task_type
    return [] unless @todo_status && @task_type

    collect_reminded_deadlines
  end

  def collect_reminded_deadlines
    reminded = []
    OwnerFinance::Deadline.active.order(:due_on, :id).find_each do |deadline|
      diff = deadline.days_left(@reference_date)
      next unless should_remind?(deadline, diff)

      task = find_or_create_crm_task(deadline, diff)
      deadline.update!(last_reminded_on: @reference_date, last_reminded_offset: diff)
      reminded << { deadline_id: deadline.id, title: deadline.title, days_left: diff, crm_task_id: task.id }
    end
    reminded
  end

  def should_remind?(deadline, diff)
    return false if deadline.last_reminded_on == @reference_date && deadline.last_reminded_offset == diff

    deadline.remind_days.include?(diff) || (diff.negative? && deadline.last_reminded_on != @reference_date)
  end

  def resolve_workspace_account(owner)
    return nil unless owner

    acc = Account.find_by(id: OwnerFinance::AccessPolicy.workspace_account_id)
    return nil unless acc

    member_ids = acc.account_users.pluck(:user_id)
    return acc if member_ids == [owner.id]

    Rails.logger.warn("[OwnerFinance::DeadlineReminderService] Workspace ##{acc.id} is not exclusive to owner ##{owner.id}")
    nil
  end

  def find_or_create_crm_task(deadline, diff)
    idem_key = "owner_finance:deadline:#{deadline.id}:#{deadline.due_on.iso8601}:d#{diff}"
    Crm::Task.find_by(account_id: @workspace_account.id, idempotency_key: idem_key) ||
      Crm::Task.create!(crm_task_attributes(deadline, diff, idem_key))
  end

  def resolve_todo_status
    Crm::TaskStatus.find_by(account_id: @workspace_account.id, code: 'todo') ||
      Crm::TaskStatus.where(account_id: @workspace_account.id, category: 'open').order(:position, :id).first
  end

  def resolve_task_type
    Crm::TaskType.find_by(account_id: @workspace_account.id, code: 'task') ||
      Crm::TaskType.where(account_id: @workspace_account.id).order(:position, :id).first
  end

  def crm_task_attributes(deadline, diff, idem_key)
    {
      account_id: @workspace_account.id, status_id: @todo_status.id,
      task_type_id: @task_type.id, activity_type: @task_type.code,
      assignee_id: @owner.id, creator_id: @owner.id, priority: diff <= 2 ? 'high' : 'medium',
      all_day: true, due_on: @reference_date, idempotency_key: idem_key, external_ref: idem_key,
      title: build_title(deadline, diff), description: build_description(deadline, diff)
    }
  end

  def build_title(deadline, diff)
    prefix = title_prefix(diff)
    rebill_tag = deadline.payer_mode == 'rebill_client' ? ' · Перевыставить клиенту' : ''
    amount_tag = deadline.amount.to_d.positive? ? " · #{format_money(deadline.amount, deadline.currency)}" : ''
    "#{prefix} #{deadline.title}#{rebill_tag}#{amount_tag}".slice(0, 240)
  end

  def title_prefix(diff)
    return "[Просрочено #{diff.abs} дн.]" if diff.negative?
    return '[Сегодня срок]' if diff.zero?

    "[Через #{diff} дн.]"
  end

  def build_description(deadline, diff)
    parts = base_description_lines(deadline, diff)
    append_optional_lines(parts, deadline)
    parts.join("\n")
  end

  def base_description_lines(deadline, diff)
    cat = CATEGORY_LABELS.fetch(deadline.category, deadline.category)
    [
      "Категория: #{cat}",
      "Крайняя дата: #{deadline.due_on.strftime('%d.%m.%Y')} (#{diff.zero? ? 'день в день' : "#{diff} дн."})"
    ]
  end

  def append_optional_lines(parts, deadline)
    parts << "Домен: #{deadline.related_domain}" if deadline.related_domain.present?
    parts << "Клиент: #{deadline.client_name}" if deadline.client_name.present?
    parts << "Сумма: #{format_money(deadline.amount, deadline.currency)}" if deadline.amount.to_d.positive?
    parts << 'Нужно выставить счёт клиенту на продление.' if deadline.payer_mode == 'rebill_client'
    parts << deadline.notes if deadline.notes.present?
  end

  def format_money(amount, currency)
    "#{amount.to_d.round(0).to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1 ').reverse} #{currency}"
  end
end
