export const UI = Object.freeze({
  TITLE: 'Финансы и сроки',
  OWNER_BADGE: 'Только владелец',
  LOCAL_DB_NOTE: '100% в PostgreSQL OneLink',
  UPLOAD_STATEMENT: 'Загрузить выписку',
  UPLOADING: 'Импорт...',
  ADD_DEADLINE: 'Добавить срок',
  ADD_TRANSACTION: 'Операция',
  ADD_ACCOUNT: 'Счёт',
  ADD_CONTRACT: 'Договор',
  ADD_OBLIGATION: 'Обязательство',
  REFRESH: 'Обновить',
  SAVE: 'Сохранить',
  CANCEL: 'Отмена',
  EDIT: 'Изменить',
  DELETE: 'Удалить',
  CLOSE: 'Закрыть',
  LOADING: 'Загрузка финансовых данных...',
  ERROR_TITLE: 'Не удалось загрузить финансовый раздел',
  RETRY: 'Повторить',

  TABS: {
    OVERVIEW: 'Обзор',
    DEADLINES: 'Сроки и продления',
    TRANSACTIONS: 'Выписки и расходы',
    CONTRACTS: 'Договоры, МедЭлемент 30% и 1С',
  },

  KPI: {
    FREE_CASH: 'Свободные деньги бизнеса',
    ON_ACCOUNTS: 'На бизнес-счетах:',
    COMMITTED_30D: 'Обязательства 30 дн.:',
    EXPECTED_30D: 'Ожидается за 30 дней',
    CONTRACTS_MRR: 'Подписки MRR:',
    REBILL_CLIENTS: 'Перевыставить клиентам:',
    PERIOD_PROFIT: 'Прибыль бизнеса за период',
    REVENUE: 'Выручка:',
    EXPENSES: 'Расходы:',
    RADAR_AND_CARDS: 'Сроки и разбор карт',
    URGENT_DEADLINES: 'Сроков ≤ 14 дн.:',
    NEEDS_REVIEW: 'С карт на разбор:',
  },

  OVERVIEW: {
    REVIEW_BANNER_PREFIX: 'Новых операций с личных карт на разбор:',
    REVIEW_BANNER_ACTION: 'Разобрать (Бизнес / Личное)',
    UPCOMING_TITLE: 'Ближайшие сроки и продления (30 дней)',
    ALL_DEADLINES_LINK: 'Все сроки',
    NO_UPCOMING: 'В ближайшие 30 дней активных сроков и продлений нет.',
    COMPLETE_BTN: 'Продлить / Закрыть',
    ACCOUNTS_TITLE: 'Счета бизнеса и карты-фильтры',
    BUSINESS_ACCOUNTS_SUB: 'Бизнес-счета (участвуют в расчёте свободных денег)',
    PERSONAL_CARDS_SUB:
      'Личные карты (только фильтр бизнес-расходов, остаток не смешивается)',
    NO_ACCOUNTS: 'Счета ещё не добавлены.',
    EXPENSE_STRUCTURE_TITLE: 'Структура расходов бизнеса за период',
    NO_EXPENSES: 'За выбранный период подтверждённых расходов нет.',
    YEAR_PNL_TITLE: 'Помесячный P&L бизнеса за год',
    COL_MONTH: 'Месяц',
    COL_REV: 'Выручка',
    COL_EXP: 'Расходы',
    COL_NET: 'Прибыль',
  },

  DEADLINES: {
    SEARCH_PLACEHOLDER: 'Поиск по названию, домену, клиенту или провайдеру...',
    ONLY_REBILL: 'Только перевыставить клиенту',
    SHOW_COMPLETED: 'Показать закрытые',
    RUN_REMINDERS_BTN: 'Проверить и создать задачи (7/3/2/1/0 дн.)',
    COL_DEADLINE: 'Срок / Домен / Клиент',
    COL_CATEGORY: 'Тип',
    COL_PAYER: 'Кто платит',
    COL_DUE: 'Крайняя дата',
    COL_AMOUNT: 'Сумма',
    COL_ACTIONS: 'Действия',
    EMPTY: 'По выбранному фильтру сроков нет.',
    REBILL_TAG: 'Перевыставить клиенту',
    REMIND_HINT:
      'Напоминания в Задачи OneLink: за 7, 3, 2, 1 и 0 дней до срока',
  },

  TX: {
    UPLOAD_ACCOUNT_ANY: 'Автоопределение счёта / карты',
    UPLOAD_HINT:
      'Поддерживаются PDF Kaspi Gold, Freedom, Halyk, 1С (.txt) и CSV',
    PRIVACY_NOTE:
      'Личные траты не хранятся: кнопка «Личное» удаляет текст операции и сохраняет только анонимный SHA-256 отпечаток.',
    TOMBSTONES_COUNT: 'Скрыто отпечатков:',
    NEEDS_REVIEW_TITLE: 'Операции с карт на разбор: Бизнес или Личное',
    NEEDS_REVIEW_EMPTY: 'Очередь чиста — неразобранных операций с карт нет.',
    CONFIRM_BUSINESS_BTN: 'Бизнес',
    HIDE_PERSONAL_BTN: 'Личное',
    HIDE_ALWAYS_BTN: 'Всегда скрывать магазин',
    CONFIRMED_TITLE: 'Подтверждённые операции бизнеса за период',
    FILTER_ALL: 'Все',
    FILTER_INCOME: 'Доходы',
    FILTER_EXPENSE: 'Расходы',
    FILTER_TRANSFER: 'Подотчёт',
    SEARCH_PLACEHOLDER: 'Поиск по контрагенту или назначению...',
    COL_DATE: 'Дата',
    COL_MERCHANT: 'Контрагент / Назначение',
    COL_CATEGORY: 'Статья P&L',
    COL_SOURCE: 'Контур',
    COL_AMOUNT: 'Сумма',
    COL_ACTIONS: 'Действия',
    EMPTY_CONFIRMED: 'За выбранный период операций нет.',
    SOURCE_1C: '1С / ИП',
    SOURCE_MGMT: 'Карта / Упр.',
  },

  CONTRACTS: {
    SECTION_TITLE: 'Клиентские договоры и подписки OneLink',
    COL_CLIENT: 'Клиент / Договор',
    COL_TARIFF: 'Тариф OneLink',
    COL_MRR: 'MRR / мес',
    COL_MEDELEMENT: 'МИС МедЭлемент',
    COL_EXPIRES: 'Действует до',
    COL_STATUS: 'Статус',
    COL_ACTIONS: 'Действия',
    EMPTY: 'Договоры ещё не добавлены.',
    DIRECT_ZERO: 'Прямой (0%)',
    MEDELEMENT_30_PREFIX: '30% =',
    EXPIRY_AUTO_NOTE:
      'Дата окончания договора автоматически создаёт срок в разделе «Сроки и продления».',
    OBLIGATIONS_TITLE:
      'Комиссия МИС МедЭлемент (30% только с базы), партнёры и долги',
    OB_FILTER_OPEN: 'Все открытые',
    OB_FILTER_MED: 'МедЭлемент 30%',
    OB_FILTER_PARTNER: 'Партнёры',
    OB_FILTER_REC: 'Нам должны',
    OB_FILTER_PAY: 'Мы должны',
    OB_FILTER_PAID: 'Закрытые',
    OB_COL_TITLE: 'Обязательство / Контрагент',
    OB_COL_KIND: 'Тип',
    OB_COL_BASE: 'База / Искл. перерасход',
    OB_COL_OUTSTANDING: 'Остаток к оплате',
    OB_COL_DUE: 'Срок',
    OB_MARK_PAID: 'Оплачено',
    OB_EMPTY: 'В этой вкладке обязательств нет.',
    ONEC_TITLE: 'Синхронизация банковских выписок 1С:Фреш (OData)',
    ONEC_SYNC_BTN: 'Синхронизировать 1С:Фреш',
    ONEC_NEVER: 'Синхронизация ещё не запускалась',
    ONEC_LAST: 'Последняя синхронизация:',
  },

  MODALS: {
    DEADLINE_NEW: 'Новый срок или продление',
    DEADLINE_EDIT: 'Редактировать срок',
    ACCOUNT_NEW: 'Новый счёт или карта-фильтр',
    ACCOUNT_EDIT: 'Обновить счёт и остаток',
    TX_NEW: 'Новая операция бизнеса',
    TX_EDIT: 'Редактировать операцию',
    CONTRACT_NEW: 'Новый договор клиента',
    CONTRACT_EDIT: 'Редактировать договор',
    OBLIGATION_NEW: 'Новое обязательство / расчёт',
    OBLIGATION_EDIT: 'Редактировать обязательство',
    FIELD_TITLE: 'Название',
    FIELD_CATEGORY: 'Категория',
    FIELD_PAYER_MODE: 'Кто оплачивает',
    FIELD_PROVIDER: 'Провайдер / Регистратор',
    FIELD_DOMAIN: 'Домен (если применимо)',
    FIELD_CLIENT: 'Клиент',
    FIELD_DUE_ON: 'Крайняя дата',
    FIELD_AMOUNT: 'Сумма',
    FIELD_CURRENCY: 'Валюта',
    FIELD_RECURRENCE: 'Периодичность',
    FIELD_REMIND_DAYS: 'За сколько дней напоминать (через запятую)',
    FIELD_NOTES: 'Заметки',
    FIELD_ACC_NAME: 'Название счёта / карты',
    FIELD_ACC_KIND: 'Тип счёта',
    FIELD_ACC_SCOPE: 'Учёт остатка',
    FIELD_ACC_BANK: 'Банк',
    FIELD_ACC_BALANCE: 'Текущий остаток',
    FIELD_DATE: 'Дата операции',
    FIELD_DIRECTION: 'Направление',
    FIELD_MERCHANT: 'Контрагент / Сервис',
    FIELD_DESCRIPTION: 'Описание / Назначение',
    FIELD_PNL_TREATMENT: 'Отражение в P&L',
    FIELD_OFFICIAL_STATUS: 'Контур учёта',
    FIELD_LEARN_VENDOR: 'Запомнить контрагента для будущих выписок',
    FIELD_CONTRACT_NUM: 'Номер договора',
    FIELD_TARIFF: 'Тариф OneLink',
    FIELD_MONTHLY_AMOUNT: 'Ежемесячный платёж (MRR)',
    FIELD_ONE_TIME_AMOUNT: 'Разовый платёж (внедрение)',
    FIELD_BILLING_DAY: 'День оплаты (1–31)',
    FIELD_STARTS_ON: 'Дата начала',
    FIELD_ENDS_ON: 'Дата окончания договора',
    FIELD_ONELINK_ACC_ID: 'ID аккаунта клиники в OneLink (необязательно)',
    FIELD_MEDELEMENT_ENABLED:
      'Клиент от МИС МедЭлемент (комиссия 30% только с базового тарифа)',
    FIELD_STATUS: 'Статус',
    FIELD_OB_KIND: 'Вид расчёта',
    FIELD_COUNTERPARTY: 'Контрагент / Партнёр',
    FIELD_PERIOD_LABEL: 'Период (напр. 2026-10)',
    FIELD_BASE_AMOUNT: 'База тарифа для 30%',
    FIELD_OVERAGE_EXCLUDED: 'Перерасход (0% комиссии)',
    FIELD_PAID_AMOUNT: 'Уже оплачено',
  },
});

export const MONTH_OPTIONS = Object.freeze([
  { value: 0, label: 'Весь год', short: 'Год' },
  { value: 1, label: 'Январь', short: 'Янв' },
  { value: 2, label: 'Февраль', short: 'Фев' },
  { value: 3, label: 'Март', short: 'Мар' },
  { value: 4, label: 'Апрель', short: 'Апр' },
  { value: 5, label: 'Май', short: 'Май' },
  { value: 6, label: 'Июнь', short: 'Июн' },
  { value: 7, label: 'Июль', short: 'Июл' },
  { value: 8, label: 'Август', short: 'Авг' },
  { value: 9, label: 'Сентябрь', short: 'Сен' },
  { value: 10, label: 'Октябрь', short: 'Окт' },
  { value: 11, label: 'Ноябрь', short: 'Ноя' },
  { value: 12, label: 'Декабрь', short: 'Дек' },
]);

export const DEADLINE_CATEGORY_FILTERS = Object.freeze([
  { code: 'all', label: 'Все сроки' },
  { code: 'hosting', label: 'Хостинг и серверы' },
  { code: 'client_domain', label: 'Домены клиентов' },
  { code: 'own_domain', label: 'Наши домены' },
  { code: 'contract', label: 'Договоры' },
  { code: 'personal', label: 'Мои личные и ИП' },
]);

export const DEADLINE_CATEGORY_LABELS = Object.freeze({
  hosting: 'Хостинг / Сервер',
  client_domain: 'Домен клиента',
  own_domain: 'Наш домен',
  contract: 'Договор',
  personal: 'Личное / ИП',
});

export const PAYER_MODE_OPTIONS = Object.freeze([
  { code: 'us', label: 'Платим мы (расход бизнеса)' },
  { code: 'rebill_client', label: 'Платим мы → перевыставить клиенту' },
  { code: 'client_direct', label: 'Платит клиент напрямую (контроль срока)' },
  { code: 'incoming_milestone', label: 'Ожидаемый транш от клиента' },
]);

export const PAYER_MODE_SHORT = Object.freeze({
  us: 'Наш расход',
  rebill_client: 'Перевыставить клиенту',
  client_direct: 'Контроль клиента',
  incoming_milestone: 'Входящий транш',
});

export const RECURRENCE_OPTIONS = Object.freeze([
  { code: 'monthly', label: 'Ежемесячно' },
  { code: 'yearly', label: 'Ежегодно' },
  { code: 'quarterly', label: 'Ежеквартально' },
  { code: 'once', label: 'Разово' },
]);

export const RECURRENCE_SHORT = Object.freeze({
  monthly: 'ежемес.',
  yearly: 'ежегодно',
  quarterly: 'ежекварт.',
  once: 'разово',
});

export const ACCOUNT_KIND_OPTIONS = Object.freeze([
  { code: 'business_bank', label: 'Расчётный счёт ИП / Бизнеса' },
  { code: 'personal_card_filter', label: 'Личная карта (фильтр бизнес-трат)' },
  { code: 'cash', label: 'Касса / Резерв' },
]);

export const ACCOUNT_SCOPE_OPTIONS = Object.freeze([
  { code: 'business', label: 'Бизнес (входит в свободные деньги)' },
  { code: 'personal', label: 'Личная карта (не входит в остаток бизнеса)' },
]);

export const CONTRACT_TARIFF_OPTIONS = Object.freeze([
  { code: 'text_voice_99k', label: '99 000 ₸ — Текст + Голос (без ИИ)' },
  { code: 'ai_agent_rop_199k', label: '199 000 ₸ — Текстовый ИИ + ИИ-РОП' },
  { code: 'voice_ai_399k', label: '399 000 ₸ — Голосовой ИИ-оператор' },
  { code: 'custom', label: 'Индивидуальный / Проект' },
]);

export const CONTRACT_TARIFF_SHORT = Object.freeze({
  text_voice_99k: '99к · Текст+Голос',
  ai_agent_rop_199k: '199к · ИИ+РОП',
  voice_ai_399k: '399к · Голосовой ИИ',
  custom: 'Индивидуальный',
});

export const CONTRACT_STATUS_OPTIONS = Object.freeze([
  { code: 'active', label: 'Активен' },
  { code: 'signed', label: 'Подписан (запуск)' },
  { code: 'under_termination', label: 'На расторжении' },
  { code: 'performed', label: 'Исполнен' },
  { code: 'archived', label: 'Архив' },
]);

export const CONTRACT_STATUS_SHORT = Object.freeze({
  active: 'Активен',
  signed: 'Подписан',
  under_termination: 'Расторжение',
  performed: 'Исполнен',
  archived: 'Архив',
});

export const OBLIGATION_KIND_OPTIONS = Object.freeze([
  {
    code: 'medelement_commission',
    label: 'Комиссия МИС МедЭлемент (30% с базы)',
  },
  { code: 'partner_settlement', label: 'Взаиморасчёт с партнёром' },
  { code: 'receivable_debt', label: 'Дебиторка (нам должны)' },
  { code: 'payable_debt', label: 'Кредиторка (мы должны)' },
  { code: 'open_invoice_1c', label: 'Выставленный счёт 1С' },
]);

export const OBLIGATION_KIND_SHORT = Object.freeze({
  medelement_commission: 'МедЭлемент 30%',
  partner_settlement: 'Партнёр',
  receivable_debt: 'Нам должны',
  payable_debt: 'Мы должны',
  open_invoice_1c: 'Счёт 1С',
});

export const TX_DIRECTION_OPTIONS = Object.freeze([
  { code: 'expense', label: 'Расход' },
  { code: 'income', label: 'Доход (поступление)' },
  { code: 'transfer', label: 'Подотчёт / Перевод между своими' },
]);

export const TX_PNL_OPTIONS = Object.freeze([
  { code: 'pnl', label: 'Включать в P&L бизнеса' },
  { code: 'non_pnl', label: 'Не влияет на P&L (подотчёт / перевод)' },
  { code: 'expense_refund', label: 'Возврат расхода' },
]);

export const CURRENCY_OPTIONS = Object.freeze(['KZT', 'USD', 'EUR', 'RUB']);

const KZT_FORMATTER = new Intl.NumberFormat('ru-RU', {
  maximumFractionDigits: 0,
});

const DECIMAL_FORMATTER = new Intl.NumberFormat('ru-RU', {
  minimumFractionDigits: 0,
  maximumFractionDigits: 2,
});

const CURRENCY_SYMBOLS = {
  KZT: '₸',
  USD: '$',
  EUR: '€',
  RUB: '₽',
};

export const formatKzt = value => {
  const num = Number(value || 0);
  return `${KZT_FORMATTER.format(Math.round(num))} ₸`;
};

export const formatMoney = (amount, currency = 'KZT') => {
  const cur = String(currency || 'KZT').toUpperCase();
  const num = Number(amount || 0);
  const sym = CURRENCY_SYMBOLS[cur] || cur;
  if (cur === 'KZT') {
    return `${KZT_FORMATTER.format(Math.round(num))} ${sym}`;
  }
  return `${DECIMAL_FORMATTER.format(num)} ${sym}`;
};

export const formatDateRu = isoDate => {
  if (!isoDate) return '—';
  const raw = String(isoDate).slice(0, 10);
  const parts = raw.split('-');
  if (parts.length !== 3) return raw;
  return `${parts[2]}.${parts[1]}.${parts[0]}`;
};

export const formatDateTimeRu = isoDateTime => {
  if (!isoDateTime) return '—';
  const d = new Date(isoDateTime);
  if (Number.isNaN(d.getTime())) return String(isoDateTime);
  return d.toLocaleString('ru-RU', {
    timeZone: 'Asia/Almaty',
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  });
};

export const deadlineDaysBadge = deadline => {
  if (deadline.status !== 'active') {
    return {
      text: 'Закрыт',
      classes: 'bg-n-alpha-2 text-n-slate-11',
    };
  }
  const days = Number(deadline.days_left ?? 0);
  if (days < 0) {
    return {
      text: `Просрочено ${Math.abs(days)} дн.`,
      classes: 'bg-n-ruby-3 text-n-ruby-11',
    };
  }
  if (days === 0) {
    return {
      text: 'Сегодня срок',
      classes: 'bg-n-ruby-3 text-n-ruby-11',
    };
  }
  if (days <= 3) {
    return {
      text: `Через ${days} дн.`,
      classes: 'bg-n-ruby-3 text-n-ruby-11',
    };
  }
  if (days <= 7) {
    return {
      text: `Через ${days} дн.`,
      classes: 'bg-n-amber-3 text-n-amber-11',
    };
  }
  return {
    text: `Через ${days} дн.`,
    classes: 'bg-n-alpha-2 text-n-slate-11',
  };
};
