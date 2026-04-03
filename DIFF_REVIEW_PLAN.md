# План ревью текущего diff

## Цель

Проверить весь текущий diff в `onelink` на соответствие следующим критериям:

- решение нативно встроено в существующую архитектуру Onelink
- поведение надежно и не ломает базовые runtime-сценарии
- код достаточно качественный и понятный для поддержки
- логика консистентна между backend, frontend, API и enterprise-слоями
- закрыты основные и базовые кейсы проекта без избыточного усложнения
- итоговое состояние выглядит целостным и production-ready
- метрики и логирование присутствуют только там, где это минимально необходимо

## Порядок проверки

1. Проверить архитектурное направление diff:
   - custom attributes mutation semantics
   - CRM field definitions/value lifecycle
   - scheduling appointment parity
   - Captain/automation/contracts
2. Проверить backend-риски:
   - partial update/delete semantics
   - validation/defaults/required fields
   - account scoping и authorization
   - cleanup/value migration behavior
   - filters/search/index-sensitive paths
3. Проверить frontend-риски:
   - консистентность payload contract
   - отображение и редактирование custom fields
   - list/board/calendar surfaces
   - automation/Captain settings UX
4. Проверить API и документацию:
   - request/response consistency
   - swagger и публичный контракт
5. Проверить тестовое покрытие диффа:
   - unit/service/request/model/frontend specs
   - наличие пропусков в критичных сценариях
6. Сформировать итоговое ревью:
   - findings по severity
   - open questions/assumptions
   - краткая оценка готовности к production

## Фокус review

- не искать идеализацию
- отсечь несущественные stylistic замечания
- выделить только реальные bugs, regressions, contract gaps и недостающие базовые кейсы
