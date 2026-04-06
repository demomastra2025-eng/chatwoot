class Captain::ToolRegistry
  class Definition
    ATTRIBUTES = %i[
      id
      title
      description
      group_name
      icon
      allowed_scopes
      agent_tool_class
      assistant_tool_class
      required_features
      required_permissions
      risk_level
      requires_confirmation
      idempotent
    ].freeze

    attr_reader(*ATTRIBUTES)

    def initialize(**attributes)
      attributes = attributes.symbolize_keys

      @id = attributes.fetch(:id)
      @title = attributes.fetch(:title)
      @description = attributes.fetch(:description)
      @group_name = attributes[:group_name]
      @icon = attributes[:icon]
      @allowed_scopes = Array(attributes.fetch(:allowed_scopes)).map(&:to_s).freeze
      @agent_tool_class = attributes[:agent_tool_class]
      @assistant_tool_class = attributes[:assistant_tool_class]
      @required_features = Array(attributes[:required_features]).map(&:to_s).freeze
      @required_permissions = Array(attributes[:required_permissions]).map(&:to_s).freeze
      @risk_level = attributes[:risk_level].presence || 'medium'
      @requires_confirmation = ActiveModel::Type::Boolean.new.cast(attributes[:requires_confirmation])
      @idempotent = ActiveModel::Type::Boolean.new.cast(attributes[:idempotent])
    end

    def supports_scope?(scope_name)
      allowed_scopes.include?(scope_name.to_s)
    end

    def tool_class_for(scope_name)
      case scope_name.to_s
      when Captain::ToolAccess::SCOPE_AGENT
        agent_tool_class
      when Captain::ToolAccess::SCOPE_ASSISTANT
        assistant_tool_class
      end
    end

    def to_h
      {
        id: id,
        title: title,
        description: description,
        group_name: group_name,
        icon: icon,
        allowed_scopes: allowed_scopes,
        required_features: required_features,
        required_permissions: required_permissions,
        risk_level: risk_level,
        requires_confirmation: requires_confirmation,
        idempotent: idempotent,
        custom: false
      }
    end
  end

  class << self
    def definitions
      @definitions ||= [
        definition(
          id: 'search_documentation',
          title: 'Search documentation',
          description: 'Search and retrieve documentation from the knowledge base',
          group_name: 'Knowledge',
          icon: 'search',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::SearchDocumentationService,
          risk_level: 'low'
        ),
        definition(
          id: 'faq_lookup',
          title: 'FAQ Lookup',
          description: 'Search FAQ responses using semantic similarity',
          group_name: 'Knowledge',
          icon: 'search',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::FaqLookupTool,
          assistant_tool_class: Captain::Tools::Copilot::FaqLookupService,
          risk_level: 'low'
        ),
        definition(
          id: 'add_contact_note',
          title: 'Add Contact Note',
          description: 'Add a note to a contact profile',
          group_name: 'Conversations',
          icon: 'note-add',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::AddContactNoteTool,
          assistant_tool_class: Captain::Tools::Copilot::AddContactNoteService,
          required_permissions: %w[contact_manage],
          risk_level: 'medium'
        ),
        definition(
          id: 'add_private_note',
          title: 'Add Private Note',
          description: 'Add a private note to a conversation',
          group_name: 'Conversations',
          icon: 'eye-off',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::AddPrivateNoteTool,
          assistant_tool_class: Captain::Tools::Copilot::AddPrivateNoteService,
          required_permissions: %w[
            conversation_manage
            conversation_unassigned_manage
            conversation_participating_manage
          ],
          risk_level: 'medium'
        ),
        definition(
          id: 'add_label_to_conversation',
          title: 'Add Label to Conversation',
          description: 'Add a label to the current conversation',
          group_name: 'Conversations',
          icon: 'tag',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::AddLabelToConversationTool,
          assistant_tool_class: Captain::Tools::Copilot::AddLabelToConversationService,
          required_permissions: %w[
            conversation_manage
            conversation_unassigned_manage
            conversation_participating_manage
          ],
          risk_level: 'medium'
        ),
        definition(
          id: 'update_priority',
          title: 'Update Priority',
          description: 'Update conversation priority level',
          group_name: 'Conversations',
          icon: 'exclamation-triangle',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::UpdatePriorityTool,
          assistant_tool_class: Captain::Tools::Copilot::UpdatePriorityService,
          required_permissions: %w[
            conversation_manage
            conversation_unassigned_manage
            conversation_participating_manage
          ],
          risk_level: 'medium'
        ),
        definition(
          id: 'resolve_conversation',
          title: 'Resolve Conversation',
          description: 'Resolve a conversation when the issue has been addressed',
          group_name: 'Conversations',
          icon: 'checkmark',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::ResolveConversationTool,
          assistant_tool_class: Captain::Tools::Copilot::ResolveConversationService,
          required_permissions: %w[
            conversation_manage
            conversation_unassigned_manage
            conversation_participating_manage
          ],
          risk_level: 'medium'
        ),
        definition(
          id: 'handoff',
          title: 'Handoff to Human',
          description: 'Hand off the current conversation to a human team',
          group_name: 'Conversations',
          icon: 'user-switch',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::HandoffTool,
          assistant_tool_class: Captain::Tools::Copilot::HandoffService,
          required_permissions: %w[
            conversation_manage
            conversation_unassigned_manage
            conversation_participating_manage
          ],
          risk_level: 'medium'
        ),
        definition(
          id: 'get_conversation',
          title: 'Get Conversation',
          description: 'Open one conversation with its messages and contact context',
          group_name: 'Conversations',
          icon: 'chat',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::GetConversationService,
          required_permissions: %w[
            conversation_manage
            conversation_unassigned_manage
            conversation_participating_manage
          ],
          risk_level: 'low'
        ),
        definition(
          id: 'search_conversations',
          title: 'Search Conversations',
          description: 'Search conversations by status, priority, contact, or labels',
          group_name: 'Conversations',
          icon: 'search',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::SearchConversationsService,
          required_permissions: %w[
            conversation_manage
            conversation_unassigned_manage
            conversation_participating_manage
          ],
          risk_level: 'low'
        ),
        definition(
          id: 'get_contact',
          title: 'Get Contact',
          description: 'Open one contact profile with its details',
          group_name: 'Contacts',
          icon: 'user',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::GetContactService,
          required_permissions: %w[contact_manage],
          risk_level: 'low'
        ),
        definition(
          id: 'search_contacts',
          title: 'Search Contacts',
          description: 'Search contacts by name, email, or phone number',
          group_name: 'Contacts',
          icon: 'search',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::SearchContactsService,
          required_permissions: %w[contact_manage],
          risk_level: 'low'
        ),
        definition(
          id: 'update_contact',
          title: 'Update Contact',
          description: 'Update the current conversation contact',
          group_name: 'Contacts',
          icon: 'user-edit',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::UpdateContactTool,
          assistant_tool_class: Captain::Tools::Copilot::UpdateContactService,
          required_permissions: %w[contact_manage],
          risk_level: 'medium'
        ),
        definition(
          id: 'get_company',
          title: 'Get Company',
          description: 'Open one company with its details',
          group_name: 'Companies',
          icon: 'briefcase',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::GetCompanyService,
          risk_level: 'low'
        ),
        definition(
          id: 'search_companies',
          title: 'Search Companies',
          description: 'Search companies by name or domain',
          group_name: 'Companies',
          icon: 'search',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::SearchCompaniesService,
          risk_level: 'low'
        ),
        definition(
          id: 'create_company',
          title: 'Create Company',
          description: 'Create a company for the current conversation contact',
          group_name: 'Companies',
          icon: 'briefcase',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::CreateCompanyTool,
          assistant_tool_class: Captain::Tools::Copilot::CreateCompanyService,
          required_permissions: %w[contact_manage],
          risk_level: 'high',
          idempotent: true
        ),
        definition(
          id: 'update_company',
          title: 'Update Company',
          description: 'Update the current conversation company',
          group_name: 'Companies',
          icon: 'briefcase-edit',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::UpdateCompanyTool,
          assistant_tool_class: Captain::Tools::Copilot::UpdateCompanyService,
          required_permissions: %w[contact_manage],
          risk_level: 'medium'
        ),
        definition(
          id: 'get_deal',
          title: 'Get Deal',
          description: 'Open one CRM deal with its details',
          group_name: 'CRM Deals',
          icon: 'money',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::GetDealService,
          required_features: %w[crm_deals],
          required_permissions: %w[crm_deal_view crm_deal_manage],
          risk_level: 'low'
        ),
        definition(
          id: 'search_deals',
          title: 'Search Deals',
          description: 'Search CRM deals by title, stage, owner, or company',
          group_name: 'CRM Deals',
          icon: 'search',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::SearchDealsService,
          required_features: %w[crm_deals],
          required_permissions: %w[crm_deal_view crm_deal_manage],
          risk_level: 'low'
        ),
        definition(
          id: 'get_deal_timeline',
          title: 'Get Deal Timeline',
          description: 'Open the timeline for one CRM deal',
          group_name: 'CRM Deals',
          icon: 'history',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::GetDealTimelineService,
          required_features: %w[crm_deals],
          required_permissions: %w[crm_deal_view crm_deal_manage],
          risk_level: 'low'
        ),
        definition(
          id: 'create_deal',
          title: 'Create Deal',
          description: 'Create a CRM deal from the current conversation context',
          group_name: 'CRM Deals',
          icon: 'money',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::CreateDealTool,
          assistant_tool_class: Captain::Tools::Copilot::CreateDealService,
          required_features: %w[crm_deals],
          required_permissions: %w[crm_deal_manage],
          risk_level: 'high',
          idempotent: true
        ),
        definition(
          id: 'update_deal',
          title: 'Update Deal',
          description: 'Update the current conversation deal',
          group_name: 'CRM Deals',
          icon: 'money-edit',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::UpdateDealTool,
          assistant_tool_class: Captain::Tools::Copilot::UpdateDealService,
          required_features: %w[crm_deals],
          required_permissions: %w[crm_deal_manage],
          risk_level: 'medium'
        ),
        definition(
          id: 'transition_deal_stage',
          title: 'Transition Deal Stage',
          description: 'Move the current conversation deal to another stage',
          group_name: 'CRM Deals',
          icon: 'arrow-right',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::TransitionDealStageTool,
          assistant_tool_class: Captain::Tools::Copilot::TransitionDealStageService,
          required_features: %w[crm_deals],
          required_permissions: %w[crm_deal_manage],
          risk_level: 'high'
        ),
        definition(
          id: 'add_deal_comment',
          title: 'Add Deal Comment',
          description: 'Add a comment to the current conversation deal',
          group_name: 'CRM Deals',
          icon: 'comment',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::AddDealCommentService,
          required_features: %w[crm_deals],
          required_permissions: %w[crm_deal_manage],
          risk_level: 'medium'
        ),
        definition(
          id: 'get_task',
          title: 'Get Task',
          description: 'Open one CRM task with its details',
          group_name: 'CRM Tasks',
          icon: 'checklist',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::GetTaskService,
          required_features: %w[crm_tasks],
          required_permissions: %w[crm_task_view crm_task_manage],
          risk_level: 'low'
        ),
        definition(
          id: 'search_tasks',
          title: 'Search Tasks',
          description: 'Search CRM tasks by title, status, assignee, or deal',
          group_name: 'CRM Tasks',
          icon: 'search',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::SearchTasksService,
          required_features: %w[crm_tasks],
          required_permissions: %w[crm_task_view crm_task_manage],
          risk_level: 'low'
        ),
        definition(
          id: 'get_task_timeline',
          title: 'Get Task Timeline',
          description: 'Open the timeline for one CRM task',
          group_name: 'CRM Tasks',
          icon: 'history',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::GetTaskTimelineService,
          required_features: %w[crm_tasks],
          required_permissions: %w[crm_task_view crm_task_manage],
          risk_level: 'low'
        ),
        definition(
          id: 'create_task',
          title: 'Create Task',
          description: 'Create a CRM task from the current conversation context',
          group_name: 'CRM Tasks',
          icon: 'checklist',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::CreateTaskTool,
          assistant_tool_class: Captain::Tools::Copilot::CreateTaskService,
          required_features: %w[crm_tasks],
          required_permissions: %w[crm_task_manage],
          risk_level: 'high',
          idempotent: true
        ),
        definition(
          id: 'update_task',
          title: 'Update Task',
          description: 'Update the current conversation task',
          group_name: 'CRM Tasks',
          icon: 'checklist-edit',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::UpdateTaskTool,
          assistant_tool_class: Captain::Tools::Copilot::UpdateTaskService,
          required_features: %w[crm_tasks],
          required_permissions: %w[crm_task_manage],
          risk_level: 'medium'
        ),
        definition(
          id: 'change_task_status',
          title: 'Change Task Status',
          description: 'Change the status of the current conversation task',
          group_name: 'CRM Tasks',
          icon: 'shuffle',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::ChangeTaskStatusTool,
          assistant_tool_class: Captain::Tools::Copilot::ChangeTaskStatusService,
          required_features: %w[crm_tasks],
          required_permissions: %w[crm_task_manage],
          risk_level: 'high'
        ),
        definition(
          id: 'add_task_comment',
          title: 'Add Task Comment',
          description: 'Add a comment to the current conversation task',
          group_name: 'CRM Tasks',
          icon: 'comment',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::AddTaskCommentService,
          required_features: %w[crm_tasks],
          required_permissions: %w[crm_task_manage],
          risk_level: 'medium'
        ),
        definition(
          id: 'get_appointment',
          title: 'Get Appointment',
          description: 'Open one appointment with its details',
          group_name: 'Scheduling',
          icon: 'calendar',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::GetAppointmentService,
          required_features: %w[scheduling],
          risk_level: 'low'
        ),
        definition(
          id: 'search_appointments',
          title: 'Search Appointments',
          description: 'Search appointments by client, status, payment status, or specialist',
          group_name: 'Scheduling',
          icon: 'search',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::SearchAppointmentsService,
          required_features: %w[scheduling],
          risk_level: 'low'
        ),
        definition(
          id: 'search_scheduling_resources',
          title: 'Search Specialists',
          description: 'Search scheduling specialists by name or specialty',
          group_name: 'Scheduling',
          icon: 'user',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::SearchSchedulingResourcesService,
          required_features: %w[scheduling],
          risk_level: 'low'
        ),
        definition(
          id: 'search_scheduling_services',
          title: 'Search Services',
          description: 'Search scheduling services by name, category, or direction',
          group_name: 'Scheduling',
          icon: 'search',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::SearchSchedulingServicesService,
          required_features: %w[scheduling],
          risk_level: 'low'
        ),
        definition(
          id: 'search_available_slots',
          title: 'Search Available Slots',
          description: 'Search appointment slots for one or more specialists',
          group_name: 'Scheduling',
          icon: 'calendar',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::SearchAvailableSlotsService,
          required_features: %w[scheduling],
          risk_level: 'low'
        ),
        definition(
          id: 'create_appointment',
          title: 'Create Appointment',
          description: 'Create an appointment for the current conversation contact',
          group_name: 'Scheduling',
          icon: 'calendar-plus',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::CreateAppointmentTool,
          assistant_tool_class: Captain::Tools::Copilot::CreateAppointmentService,
          required_features: %w[scheduling],
          risk_level: 'high',
          idempotent: true
        ),
        definition(
          id: 'update_appointment',
          title: 'Update Appointment',
          description: 'Update the current conversation appointment',
          group_name: 'Scheduling',
          icon: 'calendar-edit',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::UpdateAppointmentTool,
          assistant_tool_class: Captain::Tools::Copilot::UpdateAppointmentService,
          required_features: %w[scheduling],
          risk_level: 'high'
        ),
        definition(
          id: 'cancel_appointment',
          title: 'Cancel Appointment',
          description: 'Cancel the current conversation appointment',
          group_name: 'Scheduling',
          icon: 'calendar-x',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::CancelAppointmentTool,
          assistant_tool_class: Captain::Tools::Copilot::CancelAppointmentService,
          required_features: %w[scheduling],
          risk_level: 'high'
        ),
        definition(
          id: 'get_article',
          title: 'Get Article',
          description: 'Open one help center article with its content and metadata',
          group_name: 'Help center',
          icon: 'book-open',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::GetArticleService,
          required_permissions: %w[knowledge_base_manage],
          risk_level: 'low'
        ),
        definition(
          id: 'search_articles',
          title: 'Search Articles',
          description: 'Search help center articles by query, category, or status',
          group_name: 'Help center',
          icon: 'search',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::SearchArticlesService,
          required_permissions: %w[knowledge_base_manage],
          risk_level: 'low'
        ),
        definition(
          id: 'search_linear_issues',
          title: 'Search Linear Issues',
          description: 'Search Linear issues when the integration is enabled',
          group_name: 'Integrations',
          icon: 'search',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::SearchLinearIssuesService,
          risk_level: 'low'
        )
      ].freeze
    end

    def definition_for(tool_id)
      definitions.find { |definition| definition.id == tool_id.to_s }
    end

    def definition_for_class(tool_class, scope_name:)
      definitions.find { |definition| definition.tool_class_for(scope_name) == tool_class }
    end

    def tools_for_scope(scope_name)
      definitions.select { |definition| definition.supports_scope?(scope_name) }.map(&:to_h)
    end

    def resolve_agent_tool_class(tool_id)
      definition_for(tool_id)&.tool_class_for(Captain::ToolAccess::SCOPE_AGENT)
    end

    def resolve_assistant_tool_class(tool_id)
      definition_for(tool_id)&.tool_class_for(Captain::ToolAccess::SCOPE_ASSISTANT)
    end

    private

    def definition(**attributes)
      Definition.new(**attributes)
    end
  end
end
