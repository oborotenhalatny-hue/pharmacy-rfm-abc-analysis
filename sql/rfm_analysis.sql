-- ============================================
-- RFM- и ABC-анализ клиентской базы аптечной сети
-- Автор: Екатерина Овчинникова
-- Дата: Ноябрь 2026
-- Стек: PostgreSQL, Metabase
-- ============================================

-- ============================================
-- 2.1. Подготовка данных и расчет базовых RFM-метрик
-- ============================================

WITH max_date AS (
  -- Фиксируем последнюю дату покупки (последняя дата в базе)
  SELECT MAX(datetime)::date as analysis_date
    FROM bonuscheques
),
rfm_base AS (
   -- Базовые RFM метрики по клиентам
    SELECT
        card AS client_id,
        MAX(datetime)::date as last_purchase_date,
        COUNT(DISTINCT doc_id) AS frequency,    -- количество чеков
        SUM(summ_with_disc) AS monetary,        -- общая выручка
        SUM(bonus_spent) as total_bonus_spent,
        SUM(bonus_earned) as total_bonus_earned
    FROM bonuscheques
    WHERE card IS NOT NULL   -- исключаем анонимные покупки
    GROUP BY card
),
calc_rfm AS (
   -- Считаем Recency в днях
    SELECT
        r.client_id,
        r.frequency,
        r.monetary,
        r.total_bonus_spent,
        r.total_bonus_earned,
        (md.analysis_date - r.last_purchase_date) AS recency
    FROM rfm_base r
    CROSS JOIN max_date md
)
SELECT * FROM calc_rfm;


-- ============================================
-- 2.2. Анализ распределения метрик и расчет перцентилей
-- ============================================

SELECT
   -- Recency перцентили (чем меньше, тем лучше)
  percentile_cont(0.20) WITHIN GROUP (ORDER BY recency) AS p20_recency,
  percentile_cont(0.40) WITHIN GROUP (ORDER BY recency) AS p40_recency,
  percentile_cont(0.60) WITHIN GROUP (ORDER BY recency) AS p60_recency,
  percentile_cont(0.80) WITHIN GROUP (ORDER BY recency) AS p80_recency,
   -- Frequency перцентили (чем больше, тем лучше)
  percentile_cont(0.20) WITHIN GROUP (ORDER BY frequency) AS p20_frequency,
  percentile_cont(0.40) WITHIN GROUP (ORDER BY frequency) AS p40_frequency,
  percentile_cont(0.60) WITHIN GROUP (ORDER BY frequency) AS p60_frequency,
  percentile_cont(0.80) WITHIN GROUP (ORDER BY frequency) AS p80_frequency,
  -- Monetary перцентили (чем больше, тем лучше)
  percentile_cont(0.20) WITHIN GROUP (ORDER BY monetary) AS p20_monetary,
  percentile_cont(0.40) WITHIN GROUP (ORDER BY monetary) AS p40_monetary,
  percentile_cont(0.60) WITHIN GROUP (ORDER BY monetary) AS p60_monetary,
  percentile_cont(0.80) WITHIN GROUP (ORDER BY monetary) AS p80_monetary,
  -- Общая сумма для ABC-анализа
  SUM(monetary) as total_monetary
FROM calc_rfm;


-- ============================================
-- 2.3. Присвоение RFM-оценок (scoring)
-- ============================================

rfm_scores AS (
    SELECT
        r.client_id,
        r.recency,
        r.frequency,
        r.monetary,
        r.total_bonus_spent,
        r.total_bonus_earned,
        p.total_monetary,
   -- R score (чем меньше recency, тем выше score)
        CASE
            WHEN r.recency <= p.p20_recency THEN 5
            WHEN r.recency <= p.p40_recency THEN 4
            WHEN r.recency <= p.p60_recency THEN 3
            WHEN r.recency <= p.p80_recency THEN 2
            ELSE 1
        END AS r_score,
   -- F score (чем больше frequency, тем выше score)
        CASE
            WHEN r.frequency >= p.p80_frequency THEN 5
            WHEN r.frequency >= p.p60_frequency THEN 4
            WHEN r.frequency >= p.p40_frequency THEN 3
            WHEN r.frequency >= p.p20_frequency THEN 2
            ELSE 1
        END AS f_score,
  -- M score (чем больше monetary, тем выше score)
        CASE
            WHEN r.monetary >= p.p80_monetary THEN 5
            WHEN r.monetary >= p.p60_monetary THEN 4
            WHEN r.monetary >= p.p40_monetary THEN 3
            WHEN r.monetary >= p.p20_monetary THEN 2
            ELSE 1
        END AS m_score
    FROM calc_rfm r
    CROSS JOIN percentiles p
)


-- ============================================
-- 2.4. ABC-анализ клиентской базы
-- ============================================

abc_analysis AS (
    SELECT
        rs.*,
        SUM(rs.monetary) OVER (ORDER BY rs.monetary DESC) / rs.total_monetary AS cumulative_share,
        CASE
            WHEN SUM(rs.monetary) OVER (ORDER BY rs.monetary DESC) / rs.total_monetary <= 0.80 THEN 'A'
            WHEN SUM(rs.monetary) OVER (ORDER BY rs.monetary DESC) / rs.total_monetary <= 0.95 THEN 'B'
            ELSE 'C'
        END AS abc_class
    FROM rfm_scores rs
)


-- ============================================
-- 2.5. Сегментация клиентов на основе RFM и ABC
-- ============================================

SELECT
    client_id,
    recency,
    frequency,
    monetary,
    total_bonus_spent,
    total_bonus_earned,
    r_score,
    f_score,
    m_score,
    abc_class,
    -- RFM сегмент
    CASE
     -- Чемпионы: высокие R, F, M
        WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4 THEN 'Champions'
   -- Лояльные клиенты
        WHEN r_score >= 3 AND f_score >= 4 AND m_score >= 3 THEN 'Loyal Customers'
    -- Потенциально лояльные: недавние покупки, средняя частота
        WHEN r_score >= 4 AND f_score BETWEEN 2 AND 3 THEN 'Potential Loyalists'
   -- Новые клиенты
        WHEN r_score = 5 AND f_score = 1 THEN 'New Customers'
     -- Зона риска: были активны, но давно не покупали
        WHEN r_score <= 2 AND f_score >= 3 THEN 'At Risk'
   -- Требующие внимания: были активны, но снижают активность
        WHEN r_score <= 3 AND f_score BETWEEN 2 AND 3 THEN 'Need Attention'
    -- Спящие
        WHEN r_score <= 2 AND f_score <= 2 AND m_score <= 2 THEN 'Hibernating'
  -- Потерянные
        WHEN r_score = 1 AND f_score = 1 THEN 'Lost'
        ELSE 'Others'
    END AS rfm_segment,
  -- Рекомендации для рассылки
    CASE
        WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4 THEN
  'VIP: не предлагать скидки. Предлагать новинки и premium товары'
        WHEN r_score >= 3 AND f_score >= 4 AND m_score >= 3 THEN
   'Лояльные: программа лояльности, кросс-сейл'
        WHEN r_score >= 4 AND f_score BETWEEN 2 AND 3 THEN
   'Потенциальные: персональные предложения, накопительная система'
        WHEN r_score <= 2 AND f_score >= 3 THEN
    'Risk: ПЕРСОНАЛЬНАЯ СКИДКА 10-15% (целевая группа!)'
        WHEN r_score <= 2 AND f_score <= 2 THEN
   'Lost: мощная акция "Вернись - скидка 20%" или не тратить бюджет'
        ELSE
    'Стандартные рассылки'
    END AS recommendation
FROM abc_analysis
ORDER BY r_score DESC, f_score DESC, m_score DESC;


-- ============================================
-- 2.6. Агрегация результатов для визуализации
-- ============================================

SELECT
    rfm_segment as "RFM сегмент",
    COUNT(*) as "Количество клиентов",
    ROUND(AVG(recency), 1) as "Средняя давность (дни)",
    ROUND(AVG(frequency), 1) as "Средняя частота покупок",
    ROUND(AVG(monetary), 2) as "Средний чек",
    ROUND(SUM(monetary)) as "Общая выручка",
    MAX(recommendation) as "Рекомендация"
FROM segments
GROUP BY rfm_segment
ORDER BY "Общая выручка" DESC;
