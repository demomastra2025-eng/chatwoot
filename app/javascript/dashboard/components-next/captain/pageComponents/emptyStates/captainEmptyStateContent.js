import { INBOX_TYPES } from 'dashboard/helper/inbox';

export const assistantsList = [
  {
    account_id: 2,
    config: {},
    created_at: 1736033561,
    description:
      'Умный ассистент для поддержки клиентов: автоматизирует рутинные задачи и помогает отвечать быстрее.',
    id: 4,
    name: 'Ассистент поддержки',
  },
  {
    account_id: 3,
    config: {},
    created_at: 1736033562,
    description:
      'Помогает вести контакты, напоминания и следующие шаги по клиентам в одном месте.',
    id: 5,
    name: 'CRM-ассистент',
  },
  {
    account_id: 4,
    config: {},
    created_at: 1736033563,
    description:
      'Упрощает работу с воронкой продаж, помогает отслеживать лиды и автоматизировать процессы.',
    id: 6,
    name: 'Робот продаж',
  },
  {
    account_id: 5,
    config: {},
    created_at: 1736033564,
    description:
      'Автоматически распределяет обращения, подбирает категории и ускоряет обработку запросов.',
    id: 7,
    name: 'Робот обращений',
  },
  {
    account_id: 6,
    config: {},
    created_at: 1736033565,
    description:
      'Помогает анализировать показатели, собирать отчеты и находить полезные инсайты по данным.',
    id: 8,
    name: 'Ассистент аналитики',
  },
  {
    account_id: 8,
    config: {},
    created_at: 1736033567,
    description:
      'Упрощает внутренние HR-процессы, связанные с сотрудниками, доступами и согласованиями.',
    id: 10,
    name: 'HR-ассистент',
  },
];

export const documentsList = [
  {
    account_id: 1,
    assistant: { id: 1, name: 'Ассистент поддержки' },
    content:
      'Подробное руководство по использованию фильтров диалогов для быстрой работы с обращениями.',
    created_at: 1736143272,
    external_link:
      'https://one-link.kz/hc/user-guide/articles/1677688192-how-to-use-conversation-filters',
    id: 3059,
    name: 'Как использовать фильтры диалогов? | Руководство пользователя | OneLink',
    status: 'available',
  },
  {
    account_id: 2,
    assistant: { id: 2, name: 'Робот обращений' },
    content:
      'Пошаговая инструкция по автоматическому назначению обращений и настройке рабочих процессов в OneLink.',
    created_at: 1736143273,
    external_link:
      'https://one-link.kz/hc/user-guide/articles/1677688200-automating-ticket-assignments',
    id: 3060,
    name: 'Автоматическое назначение обращений | Руководство пользователя | OneLink',
    status: 'available',
  },
  {
    account_id: 3,
    assistant: { id: 3, name: 'CRM-ассистент' },
    content:
      'Руководство по управлению профилями клиентов и поддержанию качественной истории взаимодействий.',
    created_at: 1736143274,
    external_link:
      'https://one-link.kz/hc/user-guide/articles/1677688210-managing-customer-profiles',
    id: 3061,
    name: 'Управление профилями клиентов | Руководство пользователя | OneLink',
    status: 'available',
  },
  {
    account_id: 4,
    assistant: { id: 4, name: 'Робот продаж' },
    content:
      'Узнайте, как отслеживать сделки и использовать данные для более точного прогноза продаж.',
    created_at: 1736143275,
    external_link:
      'https://one-link.kz/hc/user-guide/articles/1677688220-sales-tracking-guide',
    id: 3062,
    name: 'Руководство по отслеживанию продаж | Руководство пользователя | OneLink',
    status: 'available',
  },
  {
    account_id: 5,
    assistant: { id: 5, name: 'Робот обращений' },
    content:
      'Как эффективно создавать, обрабатывать и закрывать обращения в OneLink.',
    created_at: 1736143276,
    external_link:
      'https://one-link.kz/hc/user-guide/articles/1677688230-managing-tickets',
    id: 3063,
    name: 'Управление обращениями | Руководство пользователя | OneLink',
    status: 'available',
  },
  {
    account_id: 6,
    assistant: { id: 6, name: 'Ассистент аналитики' },
    content:
      'Подробное руководство по работе с отчетами и аналитикой для принятия решений на основе данных.',
    created_at: 1736143277,
    external_link:
      'https://one-link.kz/hc/user-guide/articles/1677688240-financial-reporting',
    id: 3064,
    name: 'Отчеты и аналитика | Руководство пользователя | OneLink',
    status: 'available',
  },
];

export const responsesList = [
  {
    account_id: 1,
    answer:
      'Messenger может быть отключен, если у вас бесплатный тариф или уже достигнут лимит подключенных каналов.',
    created_at: 1736283330,
    id: 87,
    question: 'Почему у меня отключился Messenger в OneLink?',
    status: 'pending',
    assistant: {
      account_id: 1,
      config: {},
      created_at: 1736033280,
      description:
        'Помогает с общими вопросами по системе и настройкам workspace.',
      id: 1,
      name: 'Ассистент 2',
    },
  },
  {
    account_id: 2,
    answer:
      'Подключить WhatsApp можно в разделе интеграций: выберите WhatsApp и пройдите шаги настройки канала.',
    created_at: 1736283340,
    id: 88,
    question: 'Как подключить WhatsApp к OneLink?',
    assistant: {
      account_id: 2,
      config: {},
      created_at: 1736033281,
      description: 'Помогает с подключением интеграций и первичной настройкой.',
      id: 2,
      name: 'Ассистент 3',
    },
  },
  {
    account_id: 3,
    answer:
      'Чтобы сбросить пароль, откройте страницу входа, нажмите «Забыли пароль?» и следуйте инструкции из письма.',
    created_at: 1736283350,
    id: 89,
    question: 'Как сбросить пароль в OneLink?',
    assistant: {
      account_id: 3,
      config: {},
      created_at: 1736033282,
      description:
        'Помогает с доступом, восстановлением входа и управлением workspace.',
      id: 3,
      name: 'Ассистент 4',
    },
  },
  {
    account_id: 4,
    answer:
      'Темную тему можно включить в настройках интерфейса, выбрав нужный режим отображения.',
    created_at: 1736283360,
    id: 90,
    question: 'Как включить темную тему в OneLink?',
    assistant: {
      account_id: 4,
      config: {},
      created_at: 1736033283,
      description:
        'Подсказывает по интерфейсу, отображению и пользовательским настройкам.',
      id: 4,
      name: 'Ассистент 5',
    },
  },
  {
    account_id: 5,
    answer:
      'Чтобы добавить нового сотрудника, откройте настройки, перейдите в раздел сотрудников и нажмите «Добавить сотрудника».',
    created_at: 1736283370,
    id: 91,
    question: 'Как добавить нового сотрудника в OneLink?',
    assistant: {
      account_id: 5,
      config: {},
      created_at: 1736033284,
      description: 'Помогает с управлением сотрудниками и правами доступа.',
      id: 5,
      name: 'Ассистент 6',
    },
  },
  {
    account_id: 6,
    answer:
      'Кампании позволяют отправлять целевые сообщения выбранным сегментам пользователей. Создать кампанию можно в соответствующем разделе.',
    created_at: 1736283380,
    id: 92,
    question: 'Что такое кампании в OneLink?',
    assistant: {
      account_id: 6,
      config: {},
      created_at: 1736033285,
      description:
        'Специализируется на маркетинге, кампаниях и сценариях коммуникации.',
      id: 6,
      name: 'Ассистент 7',
    },
  },
];

export const inboxes = [
  {
    id: 7,
    name: 'Email-канал',
    channel_type: INBOX_TYPES.EMAIL,
    email: 'support@one-link.kz',
  },
  {
    id: 1,
    name: 'Чат на сайте',
    channel_type: INBOX_TYPES.WEB,
  },
  {
    id: 2,
    name: 'Facebook-канал',
    channel_type: INBOX_TYPES.FB,
  },
  {
    id: 5,
    name: 'SMS-канал',
    channel_type: INBOX_TYPES.TWILIO,
    messaging_service_sid: 'MGxxxxxx',
  },
  {
    id: 6,
    name: 'WhatsApp KZ',
    channel_type: INBOX_TYPES.WHATSAPP,
    phone_number: '+77015554433',
  },
  {
    id: 8,
    name: 'Telegram-канал',
    channel_type: INBOX_TYPES.TELEGRAM,
  },
  {
    id: 9,
    name: 'LINE-канал',
    channel_type: INBOX_TYPES.LINE,
  },
  {
    id: 10,
    name: 'API-канал',
    channel_type: INBOX_TYPES.API,
  },
  {
    id: 11,
    name: 'SMS KZ',
    channel_type: INBOX_TYPES.SMS,
    phone_number: '+77025556677',
  },
];
