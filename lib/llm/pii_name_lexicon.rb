# frozen_string_literal: true

require 'openssl'
require 'securerandom'

module Llm; end

require_relative 'pii_feedback_metrics'

# In-memory dictionary of unique first names (split into female, male, and international),
# last names, and patronymics (RU/KK/LAT). Loads all unique names from Contact and
# Scheduling::Appointment columns on startup and caches in RAM with 0 per-message DB queries.
# rubocop:disable Metrics/ModuleLength, Metrics/CollectionLiteralLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/AbcSize, Metrics/MethodLength, Style/GlobalVars
module Llm::PiiNameLexicon
  LEXICON_TTL_SECONDS = 1800 # 30 minutes
  TENANT_CACHE_TTL_SECONDS = 30
  CASE_SUFFIX_PATTERN = /
    (?:овой|евой|иной|ому|ему|ыми|ими|ого|его|ой|ей|ом|ем|ами|ями|ах|ях|ую|юю|
       ның|нің|дың|дің|тың|тің|нда|нде|нан|нен|дан|ден|тан|тен|ға|ге|қа|ке|ны|ні|ды|ді|ты|ті|мен|бен|пен|
       у|ю|а|я|е|ы|и)\z
  /xiu

  AMBIGUOUS_SINGLE_WORDS = %w[
    вера любовь надежда роза алма мир май заря слава рахмет салем сәлем
    кенес кеңес арман женис жеңіс куат қуат бақыт бакыт
  ].to_set.freeze

  FEMALE_FIRST_NAMES = %w[
    айжан айгуль айгүл алия әлия мадина мәдина динара асем әсем анна мария александра
    елена ольга наталья наталия татьяна ирина светлана екатерина юлия дарья полина
    виктория алина кристина ксения марина оксана галина людмила вероника валерия диана
    камила камилла карина софия софья милана амина әмина айлин айша медина райана
    асылым айзере аружан аяулым кәусар каусар інжу инжу айару айым нурай нұрай жансая
    акбота ақбота акерке ақерке гульназ гүлназ гульнара гүлнар гульмира гүлмира
    гульжанат айнур айнұр жанар жанара сауле сәуле индира баян майра карлыгаш қарлығаш
    ботагоз ботагөз толкын толқын мөлдір молдир жибек жібек гаухар ғауһар зарина
    дильназ айдана мерей назерке симбат сымбат асель әсел анар анара лаура эльмира
    элмира фариза шұғыла шугыла аида лейла альбина венера зухра зейнеп фатима хадиша
    марьяна эльза дана сабина жамиля жәмилә алтынай айсулу айсұлу балжан маржан
    куралай құралай шахноза нигора айгерим әйгерім бота дария кәмшат камшат ләззат
    лаззат марал меруерт наргиз нургуль нұргүл раушан салтанат сара тамара улжан ұлжан
    шолпан эльнара жазира жанат жанна гульжан гүлжан айгул айман акмарал ақмарал
    мэри дженнифер линда элизабет барбара сьюзан джессика карен нэнси лиза бетти
    маргарет сандра эшли кимберли эмили мишель аманда мелисса дебора стефани ребекка
    эмма оливия изабелла миа шарлотта амелия софи хлоя фатма айше эмине мерьем ясмин
    aizhan madina dinara aliya aigerim aigul assel saule zarina kamila aruzhan anna
    maria elena olga diana mary jennifer linda elizabeth sarah jessica emily emma
    olivia sophia isabella mia charlotte amelia
  ].freeze

  MALE_FIRST_NAMES = %w[
    серик серік дастан ерлан амир әмір тимур александр дмитрий максим артем артём
    иван михаил даниил данил денис андрей сергей алексей владимир николай евгений
    павел роман константин виктор юрий олег игорь василий валерий вячеслав станислав
    вадим руслан глеб илья кирилл никита матвей ярослав федор фёдор георгий борис
    анатолий леонид геннадий виталий антон владислав григорий степан семен семён
    захар макар платон лев марк давид дамир камиль рамазан ислам мухаммед мұхаммед
    алихан әлихан айсултан айсұлтан нурислам нұрислам алдияр амирхан әмірхан арсен
    арлан мансур мансұр санжар ибрагим қайрат кайрат болат булат нурлан нұрлан аскар
    асқар бауыржан мейрам нурсултан нұрсұлтан еркебулан еркебұлан азамат берик берік
    марат талгат талғат канат қанат самат мурат мұрат рустем рүстем темирлан темірлан
    мади мәди дидар бекзат ербол айбек нурбек нұрбек адиль әділ асет әсет аян асхат
    алмас алмат айдын айдар ануар әнвар абылай абылайхан адилет әділет акылбек ақылбек
    алибек әлібек алишер әлішер амангельды амангелді асылбек асылжан багдат бағдат
    бакытжан бақытжан батыр батырхан бейбит бейбіт бекболат бекжан биржан біржан
    габит ғабит галым ғалым галымжан ғалымжан данияр дарын даулет дәулет даурен дәурен
    дархан дияс диар досжан досым еділ едиль елдос ельнур елнұр ержан еркін еркин
    ермек ернар ернур ернұр ерсайын ерсин ерсін жанибек жәнібек жанболат жандос
    жаслан жасулан жасұлан жомарт заңғар ильяс ілияс казыбек қазыбек кайыржан қайыржан
    камбар қамбар касым қасым куаныш қуаныш магжан мағжан максат мақсат мадияр малик
    мәлік медет мейіржан мейржан мирас мухтар мұхтар нариман наурызбай нургали нұрғали
    нуржан нұржан нурлыбек нұрлыбек нурым нұрым олжас орал ораз рауан рахат рашид
    ризабек ринат сабит сәбит сабыр сабыржан сакен сәкен саят сеит сейіт серикбай
    серікбай султан сұлтан сырым таир тайыр токтар тоқтар тулеген төлеген улан ұлан
    уалихан уәлихан чингиз шыңғыс шынгыс шәкәрім эльдар елдар алим әлім расул алан
    ерболат жансерик жансерік оita оспан ахмет
    джон майкл дэвид роберт уильям ричард томас чарльз стивен кевин брайан эдвард
    роналд тимоти джейсон джеффри франк эрик стефан эндрю патрик питер генри карл
    артур джозеф джеймс кристофер даниэль мэттью энтони пол джордж мехмет мустафа
    ахмед юсуф омар хасан хусейн эмре бурак серкан кемаль тарик фарид самир халид
    serik dastan erlan yerlan arman kairat bolat bulat nurlan askar bauyrzhan azamat
    marat kanat murat ruslan sanzhar asset amir timur dmitry maxim alexey alexander
    sergey andrey ivan daniyar dauren olzhas almas askhat bekzat aibek aybek
    john michael david robert william james richard thomas charles daniel matthew
    anthony paul george steven edward brian kevin jason ryan jacob eric stephen
    patrick peter henry carl arthur joseph christopher mehmet mustafa ahmed omar
  ].freeze

  BASE_FIRST_NAMES = (FEMALE_FIRST_NAMES + MALE_FIRST_NAMES).uniq.freeze

  BASE_LAST_NAMES = %w[
    ким пак ли цой хан югай хегай тян шин кан сон мун ян чен ни ан смит мюллер
    оспан оспанов оспанова ахмет ахметов ахметова сеит сейіт сеитов сеитова сейтова сейітова
    касым қасым касымов қасымов касымова қасымова нурпеис нұрпейіс нурпеисов нұрпейісов
    нурпеисова нұрпейісова смагул смағұл смагулов смағұлов смагулова смағұлова
    толеген төлеген толегенов төлегенов толегенова төлегенова алиев алиева әлиев әлиева
    иванов иванова петров петрова сидоров сидорова смирнов смирнова кузнецов кузнецова
    попов попова соколов соколова лебедев лебедева козлов козлова новиков новикова
    морозов морозова волков волкова соловьев соловьева васильев васильева зайцев зайцева
    павлов павлова семенов семенова голубев голубева виноградов виноградова богданов
    богданова воробьев воробьева федоров федорова михайлов михайлова беляев беляева
    тарасов тарасова белов белова комаров комарова орлов орлова киселев киселева
    макаров макарова андреев андреева ковалев ковалева сулейменов сүлейменов сулейменова
    сүлейменова абдрахманов әбдірахманов абдрахманова әбдірахманова искаков ысқақов
    искакова ысқақова калиев қалиев калиева қалиева садыков садықов садыкова садықова
    нургалиев нұрғалиев нургалиева нұрғалиева жумабаев жұмабаев жумабаева жұмабаева
    омаров омарова бекенов бекенова мусин мұсин мусина мұсина турсынов тұрсынов
    турсынова тұрсынова жакупов жақұпов жакупова жақұпова абишев әбішев абишева әбішева
    базарбаев базарбаева сапаров сапарова тажибаев тәжібаев тажибаева тәжібаева есимов
    есімов есимова есімова байжанов байжанова мырзахметов мырзахметова каримов кәрімов
    каримова кәрімова рахимов рахимова шарипов шәріпов шарипова шәріпова мамедов мамедова
    аубакиров әубәкіров аубакирова әубәкірова жумагулов жұмағұлов жумагулова жұмағұлова
    ибраев ыбыраев ибраева ыбыраева исаев исаева кусаинов құсайынов кусаинова құсайынова
    нурпиисов нурмаганбетов нұрмағанбетов сарсенов сәрсенов сарсенова сәрсенова
    тастанов тастанова увалиев уәлиев хасенов хасенова шаяхметов шаяхметова
    kim pak lee tsoy khan smith muller ospanov ospanova akhmetov akhmetova kasymov kasymova
    seyitova seitova nurpeisov nurpeisova smagulov smagulova tolegenov tolegenova
    aliyev aliyeva ivanov ivanova petrov petrova suleimenov abdrakhmanov omarov sadykov
  ].freeze

  BASE_PATRONYMICS = %w[
    болатович болатовна болатұлы болатқызы серикович сериковна серікұлы серікқызы
    маратович маратовна маратұлы маратқызы аскарович асқарович аскаровна асқаровна
    асқарқызы аскаркызы асқарұлы аскарулы кайратович қайратович кайратовна қайратовна
    қайратұлы кайратулы қайратқызы кайраткызы нурланович нурлановна нұрланұлы нурланулы
    нұрланқызы нурланкызы тимурович тимуровна тимурұлы тимурқызы ерланович ерлановна
    ерланұлы ерланқызы бауыржанович бауыржановна бауыржанұлы бауыржанқызы
    азаматович азаматовна азаматұлы азаматқызы канатович қанатович канатовна қанатовна
    қанатұлы қанатқызы муратович мұратович муратовна мұратовна мұратұлы мұратқызы
    талгатович талғатович талгатовна талғатовна талғатұлы талғатқызы
    сергеевич сергеевна александрович александровна владимирович владимировна
    николаевич николаевна иванович ивановна петрович петровна дмитриевич дмитриевна
    андреевич андреевна алексеевич алексеевна михайлович михайловна евгеньевич евгеньевна
    викторович викторовна юрьевич юрьевна олегович олеговна игоревич игоревна
    павлович павловна романович романовна константинович константиновна
    анатольевич анатольевна валерьевич валерьевна вячеславович вячеславовна
    геннадьевич геннадьевна борисович борисовна
  ].freeze

  LEARNED_REDIS_PREFIX = 'llm:pii_lexicon:learned:v2'
  QUARANTINE_REDIS_PREFIX = 'llm:pii_lexicon:quarantine:v2'
  TENANT_VERSION_REDIS_PREFIX = 'llm:pii_lexicon:tenant_ver:v2'
  MAX_DB_UNIQUE_NAMES = 5_000
  MAX_LEARNED_PER_TENANT = 2_000
  MAX_QUARANTINED_PER_TENANT = 500

  LEARNED_CATEGORIES = {
    first_name: %i[first_names first_stems],
    female_name: %i[female_names female_stems first_names first_stems],
    male_name: %i[male_names male_stems first_names first_stems],
    last_name: %i[last_names last_stems],
    patronymic: %i[patronymics patronymic_stems]
  }.freeze

  @lexicon_cache = nil
  @last_seen_key_version = nil
  @tenant_learned_cache = {}
  @quarantine_cache = {}
  @tracked_redis_keys = Set.new
  @lexicon_mutex = Mutex.new

  module_function

  def clear_cache!(purge_redis: defined?(Rails) && Rails.respond_to?(:env) && Rails.env.test?)
    @lexicon_mutex.synchronize do
      purge_stale_key_versions!(safe_key_version) if @last_seen_key_version && @last_seen_key_version != safe_key_version
      purge_all_redis_keys! if purge_redis
      @lexicon_cache = nil
      @tenant_learned_cache.clear
      @quarantine_cache.clear
    end
  end

  def preload!
    current_lexicon
    true
  end

  def current_key_version
    OpenSSL::Digest::SHA256.hexdigest("pii_lex_kv:v2:#{secret_material}")[0, 12].freeze
  end

  def current_lexicon
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    key_ver = current_key_version
    @lexicon_mutex.synchronize do
      return @lexicon_cache[:data] if @lexicon_cache && @lexicon_cache[:expires_at] > now && @lexicon_cache[:key_version] == key_ver

      purge_stale_key_versions!(key_ver) if @last_seen_key_version && @last_seen_key_version != key_ver
      @last_seen_key_version = key_ver
      data = build_lexicon
      @lexicon_cache = { key_version: key_ver, data: data, expires_at: now + LEXICON_TTL_SECONDS }
      data
    end
  rescue StandardError => e
    raise if e.message.include?('secret_key_base is required')

    fallback_lexicon
  end

  def first_name?(word, stopwords: Set.new, account_id: nil)
    lookup_in_category?(word, :first_names, :first_stems, stopwords: stopwords, account_id: account_id)
  end

  def female_first_name?(word, stopwords: Set.new, account_id: nil)
    lookup_in_category?(word, :female_names, :female_stems, stopwords: stopwords, account_id: account_id)
  end

  def male_first_name?(word, stopwords: Set.new, account_id: nil)
    lookup_in_category?(word, :male_names, :male_stems, stopwords: stopwords, account_id: account_id)
  end

  def last_name?(word, stopwords: Set.new, account_id: nil)
    lookup_in_category?(word, :last_names, :last_stems, stopwords: stopwords, account_id: account_id)
  end

  def patronymic?(word, stopwords: Set.new, account_id: nil)
    lookup_in_category?(word, :patronymics, :patronymic_stems, stopwords: stopwords, account_id: account_id)
  end

  def known_person_name_word?(word, stopwords: Set.new, account_id: nil)
    first_name?(word, stopwords: stopwords, account_id: account_id) ||
      last_name?(word, stopwords: stopwords, account_id: account_id) ||
      patronymic?(word, stopwords: stopwords, account_id: account_id)
  end

  def unambiguous_single_name?(word, stopwords: Set.new, account_id: nil)
    norm = normalize_word(word)
    return false if norm.length < 3
    return false if AMBIGUOUS_SINGLE_WORDS.include?(norm) || AMBIGUOUS_SINGLE_WORDS.include?(stem_word(norm))

    first_name?(word, stopwords: stopwords, account_id: account_id) ||
      last_name?(word, stopwords: stopwords, account_id: account_id)
  end

  # Places an unverified candidate word (e.g., from async decider) into a tenant-scoped quarantine set.
  # Quarantined digests are NOT active in live masking until verified and promoted.
  def quarantine_candidate!(word, category: :first_name, account_id: nil, confidence: 0.0, feedback: false, **_metadata) # rubocop:disable Lint/UnusedMethodArgument, Metrics/ParameterLists
    acct_id = resolve_account_id(account_id)
    return false if acct_id.nil?

    norm = normalize_word(word)
    return false if norm.length < 2 || AMBIGUOUS_SINGLE_WORDS.include?(norm)

    key_ver = current_key_version
    hex_exact = hmac_digest(norm).unpack1('H*')
    cat_key = LEARNED_CATEGORIES.key?(category.to_sym) ? category.to_sym : :first_name
    r_key = "#{QUARANTINE_REDIS_PREFIX}:kv_#{key_ver}:acct_#{acct_id}:#{cat_key}"

    added = persist_quarantined_digest!(r_key, hex_exact, account_id: acct_id, feedback: feedback)
    return false unless added

    @lexicon_mutex.synchronize do
      q_set = (@quarantine_cache["#{key_ver}:#{acct_id}:#{cat_key}"] ||= Set.new)
      q_set << hex_exact
      @tracked_redis_keys << r_key
    end
    true
  rescue StandardError
    false
  end

  def quarantined_candidate?(word, category: :first_name, account_id: nil)
    acct_id = resolve_account_id(account_id)
    return false if acct_id.nil?

    norm = normalize_word(word)
    return false if norm.length < 2

    key_ver = current_key_version
    hex_exact = hmac_digest(norm).unpack1('H*')
    cat_key = LEARNED_CATEGORIES.key?(category.to_sym) ? category.to_sym : :first_name
    r_key = "#{QUARANTINE_REDIS_PREFIX}:kv_#{key_ver}:acct_#{acct_id}:#{cat_key}"

    in_ram = @lexicon_mutex.synchronize { @quarantine_cache["#{key_ver}:#{acct_id}:#{cat_key}"]&.include?(hex_exact) }
    return true if in_ram

    Array(redis_smembers(r_key)).include?(hex_exact)
  rescue StandardError
    false
  end

  def promote_quarantined_word!(word, category: :first_name, account_id: nil, verified: false)
    return false unless verified

    acct_id = resolve_account_id(account_id)
    return false if acct_id.nil?
    return false unless quarantined_candidate?(word, category: category, account_id: acct_id)

    learn_word!(word, category: category, account_id: acct_id, verified: true)
  end

  # Adds a verified name digest strictly to the given tenant (account_id), never globally across tenants.
  def learn_word!(word, category: :first_name, account_id: nil, verified: false, feedback: false)
    return false unless verified

    acct_id = resolve_account_id(account_id)
    return false if acct_id.nil?

    norm = normalize_word(word)
    return false if norm.length < 2

    key_ver = current_key_version
    exact_hash = hmac_digest(norm)
    stem = stem_word(norm)
    stem_hash = stem.length >= 3 ? hmac_digest(stem) : nil

    added = persist_learned_digest!(key_ver, acct_id, category.to_sym, [exact_hash, stem_hash], feedback: feedback)
    return false unless added

    @lexicon_mutex.synchronize { @tenant_learned_cache.delete("#{key_ver}:#{acct_id}") }
    true
  end

  def purge_stale_key_versions!(active_kv = current_key_version)
    stale_keys = @tracked_redis_keys.reject { |k| k.include?("kv_#{active_kv}") }
    scan_redis_prefix_keys.each { |k| stale_keys << k unless k.include?("kv_#{active_kv}") }
    stale_keys.uniq.each do |k|
      delete_redis_key!(k)
      @tracked_redis_keys.delete(k)
    end
    @tenant_learned_cache.delete_if { |k, _| !k.start_with?("#{active_kv}:") }
    @quarantine_cache.delete_if { |k, _| !k.start_with?("#{active_kv}:") }
  rescue StandardError
    nil
  end

  def purge_all_redis_keys!
    (@tracked_redis_keys.to_a + scan_redis_prefix_keys).uniq.each do |k|
      delete_redis_key!(k)
      @tracked_redis_keys.delete(k)
    end
  rescue StandardError
    nil
  end

  def scan_redis_prefix_keys
    found = []
    if defined?($alfred) && $alfred.respond_to?(:with)
      $alfred.with do |conn|
        [LEARNED_REDIS_PREFIX, QUARANTINE_REDIS_PREFIX, TENANT_VERSION_REDIS_PREFIX].each do |prefix|
          Array(conn.keys("#{prefix}:*")).each { |key| found << key }
        end
      end
    end
    found
  rescue StandardError
    []
  end

  def stats
    lex = current_lexicon
    {
      key_version: current_key_version,
      unique_first_names: lex[:first_names].size,
      unique_female_names: lex[:female_names].size,
      unique_male_names: lex[:male_names].size,
      unique_last_names: lex[:last_names].size,
      unique_patronymics: lex[:patronymics].size,
      unique_stems_total: lex[:first_stems].size + lex[:last_stems].size + lex[:patronymic_stems].size
    }
  end

  def normalize_word(word)
    word.to_s.unicode_normalize(:nfkc).downcase.strip
  end

  def stem_word(norm_word)
    return norm_word if norm_word.length < 4

    stemmed = norm_word.sub(CASE_SUFFIX_PATTERN, '')
    stemmed.length >= 3 ? stemmed : norm_word
  end

  def hmac_digest(norm_str)
    OpenSSL::HMAC.digest('SHA256', secret_material, "pii_lex:v2:#{norm_str}")[0, 12].freeze
  end

  def secret_material
    key = defined?(Rails) && Rails.respond_to?(:application) ? Rails.application&.secret_key_base.to_s : ''
    key = ENV['SECRET_KEY_BASE'].to_s if key.blank?
    if key.blank?
      if defined?(Rails) && Rails.respond_to?(:env) && Rails.env.production?
        raise 'Rails.application.secret_key_base is required for Llm::PiiNameLexicon'
      end

      return 'onelink-nonprod-pii-name-lexicon-key'
    end
    key
  end

  def safe_key_version
    current_key_version
  rescue StandardError
    nil
  end

  def resolve_account_id(account_id)
    return account_id.to_i if account_id.present? && account_id.to_i.positive?

    if defined?(Llm::PiiSessionPseudonymizer) && Llm::PiiSessionPseudonymizer.active?
      scope_acct = Llm::PiiSessionPseudonymizer.current_scope[:account_id].to_i
      return scope_acct if scope_acct.positive?
    end
    nil
  end

  def lookup_in_category?(word, exact_key, stem_key, stopwords:, account_id: nil)
    norm = normalize_word(word)
    return false if norm.length < 2
    return false if stopwords.include?(norm)

    stem = stem_word(norm)
    return false if stopwords.include?(stem)

    lex = current_lexicon
    norm_hash = hmac_digest(norm)
    stem_hash = stem.length >= 3 ? hmac_digest(stem) : nil

    return true if match_in_sets?(lex[exact_key], lex[stem_key], norm_hash, stem_hash)

    acct_id = resolve_account_id(account_id)
    return false if acct_id.nil?

    t_sets = tenant_learned_sets(acct_id)
    return false if t_sets.nil?

    match_in_sets?(t_sets[exact_key], t_sets[stem_key], norm_hash, stem_hash)
  end

  def match_in_sets?(exact_set, stem_set, norm_hash, stem_hash)
    return true if exact_set&.include?(norm_hash)
    return false if stem_hash.nil?

    exact_set&.include?(stem_hash) || stem_set&.include?(stem_hash)
  end

  def build_lexicon
    sets = init_base_sets
    merge_database_unique_names!(sets)
    sets.transform_values(&:freeze).freeze
  end

  def fallback_lexicon
    init_base_sets.transform_values(&:freeze).freeze
  end

  def init_base_sets
    keys = %i[first_names first_stems female_names female_stems male_names male_stems last_names last_stems patronymics patronymic_stems]
    sets = keys.index_with { Set.new }
    populate_set!(sets[:female_names], sets[:female_stems], FEMALE_FIRST_NAMES)
    populate_set!(sets[:male_names], sets[:male_stems], MALE_FIRST_NAMES)
    populate_set!(sets[:first_names], sets[:first_stems], BASE_FIRST_NAMES)
    populate_set!(sets[:last_names], sets[:last_stems], BASE_LAST_NAMES)
    populate_set!(sets[:patronymics], sets[:patronymic_stems], BASE_PATRONYMICS)
    sets
  end

  def populate_set!(exact_set, stem_set, raw_list)
    Array(raw_list).each do |entry|
      entry.to_s.scan(/[[:alpha:]]{2,}/).each do |token|
        norm = normalize_word(token)
        next if norm.length < 2

        exact_set << hmac_digest(norm)
        stem = stem_word(norm)
        stem_set << hmac_digest(stem) if stem.length >= 3
      end
    end
  end

  def merge_database_unique_names!(sets)
    return unless db_ready?

    merge_contact_unique_names!(sets)
    merge_appointment_unique_names!(sets)
  rescue StandardError
    nil
  end

  def db_ready?
    defined?(ActiveRecord::Base) && ActiveRecord::Base.connected?
  end

  def merge_contact_unique_names!(sets)
    return unless defined?(Contact) && Contact.table_exists?

    with_last = Contact.where.not(last_name: [nil, ''])
    populate_set!(sets[:first_names], sets[:first_stems], pluck_unique(with_last, :name))
    populate_set!(sets[:last_names], sets[:last_stems], pluck_unique(Contact, :last_name))
    populate_set!(sets[:patronymics], sets[:patronymic_stems], pluck_unique(Contact, :middle_name))
    merge_medelement_json_names!(sets)
  end

  def merge_medelement_json_names!(sets)
    f_sql = Arel.sql("DISTINCT custom_attributes ->> 'medelement_first_name'")
    l_sql = Arel.sql("DISTINCT custom_attributes ->> 'medelement_last_name'")
    f_rel = Contact.where("custom_attributes ? 'medelement_first_name'")
    l_rel = Contact.where("custom_attributes ? 'medelement_last_name'")
    f_rel = f_rel.limit(MAX_DB_UNIQUE_NAMES) if f_rel.respond_to?(:limit)
    l_rel = l_rel.limit(MAX_DB_UNIQUE_NAMES) if l_rel.respond_to?(:limit)
    populate_set!(sets[:first_names], sets[:first_stems], f_rel.pluck(f_sql))
    populate_set!(sets[:last_names], sets[:last_stems], l_rel.pluck(l_sql))
  end

  def merge_appointment_unique_names!(sets)
    return unless defined?(Scheduling::Appointment) && Scheduling::Appointment.table_exists?

    populate_set!(sets[:first_names], sets[:first_stems], pluck_unique(Scheduling::Appointment, :client_first_name))
    populate_set!(sets[:last_names], sets[:last_stems], pluck_unique(Scheduling::Appointment, :client_last_name))
    populate_set!(sets[:patronymics], sets[:patronymic_stems], pluck_unique(Scheduling::Appointment, :client_middle_name))
  end

  def pluck_unique(scope, column)
    rel = scope.where.not(column => [nil, '']).distinct
    rel = rel.limit(MAX_DB_UNIQUE_NAMES) if rel.respond_to?(:limit)
    rel.pluck(column)
  end

  # Bounded, cross-process uniqueness. Plaintext is never a Redis member/key.
  def persist_quarantined_digest!(key, digest, account_id:, feedback:)
    return false unless defined?($alfred) && $alfred.respond_to?(:with)

    metric_keys = Llm::PiiFeedbackMetrics.keys(account_id)
    argv = [digest, MAX_QUARANTINED_PER_TENANT, feedback ? '1' : '0', Time.now.utc.iso8601]
    $alfred.with do |conn|
      if Llm::PiiFeedbackMetrics.mock?(conn)
        return Llm::PiiFeedbackMetrics.mock_atomic(conn) do
          next false if conn.scard(key) >= MAX_QUARANTINED_PER_TENANT

          result = conn.sadd(key, digest)
          next false unless result == true || result == 1

          Llm::PiiFeedbackMetrics.mock_count(conn, metric_keys, { new_quarantined_names: 1 }, argv.last) if feedback
          true
        end
      end
      script = Llm::PiiFeedbackMetrics::LUA_HELPER + <<~LUA
        expect_type(KEYS[1], 'set')
        if redis.call('SCARD', KEYS[1]) >= tonumber(ARGV[2]) then return 0 end
        if redis.call('SADD', KEYS[1], ARGV[1]) == 0 then return 0 end
        if ARGV[3] == '1' then count('new_quarantined_names', 1) end
        return 1
      LUA
      Llm::PiiFeedbackMetrics.eval_script(conn, script, keys: [key] + metric_keys, argv: argv).to_i == 1
    end
  rescue StandardError
    false
  end

  def persist_learned_digest!(key_ver, acct_id, category, digests, feedback: false)
    exact_hash, stem_hash = digests
    return false unless defined?($alfred) && $alfred.respond_to?(:with)

    exact_key = "#{LEARNED_REDIS_PREFIX}:kv_#{key_ver}:acct_#{acct_id}:#{category}:exact"
    stem_key = "#{LEARNED_REDIS_PREFIX}:kv_#{key_ver}:acct_#{acct_id}:#{category}:stem"
    ver_key = "#{TENANT_VERSION_REDIS_PREFIX}:kv_#{key_ver}:acct_#{acct_id}"
    quarantine_key = "#{QUARANTINE_REDIS_PREFIX}:kv_#{key_ver}:acct_#{acct_id}:#{category}"
    @lexicon_mutex.synchronize { @tracked_redis_keys.merge([exact_key, stem_key, ver_key]) }
    metric_keys = Llm::PiiFeedbackMetrics.keys(acct_id)
    argv = [exact_hash.unpack1('H*'), stem_hash ? stem_hash.unpack1('H*') : '', MAX_LEARNED_PER_TENANT,
            SecureRandom.hex(12), feedback ? '1' : '0', Time.now.utc.iso8601]
    $alfred.with do |conn| # rubocop:disable Metrics/BlockLength
      if Llm::PiiFeedbackMetrics.mock?(conn)
        return Llm::PiiFeedbackMetrics.mock_atomic(conn) do
          next false if conn.scard(exact_key) >= MAX_LEARNED_PER_TENANT

          result = conn.sadd(exact_key, argv[0])
          next false unless result == true || result == 1

          conn.sadd(stem_key, argv[1]) unless argv[1].empty?
          conn.set(ver_key, argv[3])
          if feedback
            counts = { verified_name_promotions: 1,
                       verified_quarantine_promotions: conn.sismember(quarantine_key, argv[0]) ? 1 : 0 }
            Llm::PiiFeedbackMetrics.mock_count(conn, metric_keys, counts, argv.last)
          end
          true
        end
      end
      script = Llm::PiiFeedbackMetrics::LUA_HELPER + <<~LUA
        expect_type(KEYS[1], 'set')
        expect_type(KEYS[2], 'set')
        expect_type(KEYS[3], 'string')
        expect_type(KEYS[4], 'set')
        if redis.call('SCARD', KEYS[1]) >= tonumber(ARGV[3]) then return 0 end
        if redis.call('SADD', KEYS[1], ARGV[1]) == 0 then return 0 end
        if ARGV[2] ~= '' then redis.call('SADD', KEYS[2], ARGV[2]) end
        redis.call('SET', KEYS[3], ARGV[4])
        if ARGV[5] == '1' then
          count('verified_name_promotions', 1)
          if redis.call('SISMEMBER', KEYS[4], ARGV[1]) == 1 then count('verified_quarantine_promotions', 1) end
        end
        return 1
      LUA
      Llm::PiiFeedbackMetrics.eval_script(conn, script, keys: [exact_key, stem_key, ver_key, quarantine_key] + metric_keys, argv: argv).to_i == 1
    end
  rescue StandardError
    false
  end

  def tenant_learned_sets(acct_id)
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    key_ver = current_key_version
    cache_key = "#{key_ver}:#{acct_id}"
    @lexicon_mutex.synchronize do
      cached = @tenant_learned_cache[cache_key]
      return cached[:sets] if cached && cached[:expires_at].to_f > now

      remote_ver = fetch_tenant_redis_version(key_ver, acct_id)
      if cached && cached[:version] == remote_ver
        cached[:expires_at] = now + TENANT_CACHE_TTL_SECONDS
        return cached[:sets]
      end

      loaded = load_tenant_sets_from_redis(key_ver, acct_id)
      return nil unless fetch_tenant_redis_version(key_ver, acct_id) == remote_ver

      @tenant_learned_cache[cache_key] = {
        version: remote_ver,
        sets: loaded,
        expires_at: now + TENANT_CACHE_TTL_SECONDS
      }
      loaded
    end
  rescue StandardError
    nil
  end

  def fetch_tenant_redis_version(key_ver, acct_id)
    raise 'PII lexicon storage unavailable' unless defined?(Redis::Alfred) && Redis::Alfred.respond_to?(:get)

    Redis::Alfred.get("#{TENANT_VERSION_REDIS_PREFIX}:kv_#{key_ver}:acct_#{acct_id}").to_s
  end

  def empty_tenant_sets
    %i[first_names first_stems female_names female_stems male_names male_stems last_names last_stems patronymics patronymic_stems].index_with do
      Set.new
    end
  end

  def load_tenant_sets_from_redis(key_ver, acct_id)
    sets = empty_tenant_sets
    Llm::PiiFeedbackMetrics.with_store do |conn|
      LEARNED_CATEGORIES.each do |category, target_keys|
        exact_key = "#{LEARNED_REDIS_PREFIX}:kv_#{key_ver}:acct_#{acct_id}:#{category}:exact"
        stem_key = "#{LEARNED_REDIS_PREFIX}:kv_#{key_ver}:acct_#{acct_id}:#{category}:stem"
        @tracked_redis_keys << exact_key
        @tracked_redis_keys << stem_key
        exact_hexes = Array(conn.smembers(exact_key)).first(MAX_LEARNED_PER_TENANT)
        stem_hexes = Array(conn.smembers(stem_key)).first(MAX_LEARNED_PER_TENANT)
        target_keys.each do |key|
          hexes = key.to_s.end_with?('_stems') ? stem_hexes : exact_hexes
          hexes.each { |hex| sets[key] << [hex].pack('H*').freeze }
        end
      end
    end
    sets
  end

  def redis_sadd(key, value)
    if defined?(Redis::Alfred) && Redis::Alfred.respond_to?(:sadd)
      Redis::Alfred.sadd(key, value)
    elsif defined?($alfred) && $alfred.respond_to?(:with)
      $alfred.with { |conn| conn.sadd(key, value) }
    end
  rescue StandardError
    nil
  end

  def redis_smembers(key)
    if defined?(Redis::Alfred) && Redis::Alfred.respond_to?(:smembers)
      Redis::Alfred.smembers(key)
    elsif defined?($alfred) && $alfred.respond_to?(:with)
      $alfred.with { |conn| conn.smembers(key) }
    else
      []
    end
  rescue StandardError
    []
  end

  def delete_redis_key!(key)
    return unless defined?(Redis::Alfred)

    Redis::Alfred.delete(key) if Redis::Alfred.respond_to?(:delete)
    Redis::Alfred.sets.delete(key) if Redis::Alfred.respond_to?(:sets) && Redis::Alfred.sets.is_a?(Hash)
    Redis::Alfred.store.delete(key) if Redis::Alfred.respond_to?(:store) && Redis::Alfred.store.is_a?(Hash)
  rescue StandardError
    nil
  end

  private_class_method :build_lexicon, :fallback_lexicon, :init_base_sets, :populate_set!, :merge_database_unique_names!,
                       :db_ready?, :merge_contact_unique_names!, :merge_medelement_json_names!,
                       :merge_appointment_unique_names!, :pluck_unique, :hmac_digest, :secret_material, :safe_key_version,
                       :resolve_account_id, :lookup_in_category?, :match_in_sets?, :persist_learned_digest!,
                       :persist_quarantined_digest!, :tenant_learned_sets, :fetch_tenant_redis_version,
                       :empty_tenant_sets, :load_tenant_sets_from_redis, :redis_sadd, :redis_smembers, :delete_redis_key!
end
# rubocop:enable Metrics/ModuleLength, Metrics/CollectionLiteralLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/AbcSize, Metrics/MethodLength, Style/GlobalVars
