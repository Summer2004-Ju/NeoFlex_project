-- 1. Правило: если account_in_sum текущего дня отличается от
-- account_out_sum предыдущего дня — правильным считается account_out_sum предыдущего дня.

with

-- шаг 1. дедупликация rd.account_balance.
balance_dedup as (
    select distinct on (account_rk, effective_date)
        account_rk,
        effective_date,
        account_in_sum,
        account_out_sum
    from rd.account_balance
    where effective_date is not null
    order by account_rk, effective_date
),

-- шаг 2. дедупликация rd.account.

account_dedup as (
    select distinct on (account_rk)
        account_rk,
        currency_cd,
        department_rk,
        effective_from_date,
        effective_to_date
    from rd.account
    order by account_rk, effective_from_date desc
),

-- шаг 3. дедупликация dm.dict_currency.

currency_dedup as (
    select distinct on (currency_cd)
        currency_cd,
        currency_name,
        effective_from_date,
        effective_to_date
    from dm.dict_currency
    order by currency_cd, effective_from_date desc
),

-- шаг 4. считаем lag на уже чистых данных.
balance_fixed as (
    select
        ab.account_rk,
        ab.effective_date,
        ab.account_in_sum  as original_in_sum,
        ab.account_out_sum as original_out_sum,
        lag(ab.account_out_sum) over (
            partition by ab.account_rk
            order by ab.effective_date
        ) as prev_out_sum
    from balance_dedup ab
)

-- шаг 5. собираем итог.
select
    a.account_rk,
    coalesce(dc.currency_name, '-1'::text) as currency_name,
    a.department_rk,
    bf.effective_date,

    -- корректный account_in_sum:
    -- если есть предыдущий день — берём его account_out_sum,
    -- если первый день счёта (lag = null) — оставляем исходный.
    coalesce(bf.prev_out_sum, bf.original_in_sum) as account_in_sum,

    bf.original_out_sum as account_out_sum

from balance_fixed bf
left join account_dedup a
       on a.account_rk = bf.account_rk
      and bf.effective_date between a.effective_from_date and a.effective_to_date
left join currency_dedup dc
       on dc.currency_cd = a.currency_cd
      and bf.effective_date between dc.effective_from_date and dc.effective_to_date
where a.department_rk is not null
order by a.account_rk, bf.effective_date;



-- 2 правило: если account_out_sum предыдущего дня отличается от
-- account_in_sum текущего дня — правильным считается account_in_sum следующего дня (смотрим вперёд через lead).


with

balance_dedup as (
    select distinct on (account_rk, effective_date)
        account_rk,
        effective_date,
        account_in_sum,
        account_out_sum
    from rd.account_balance
    where effective_date is not null
    order by account_rk, effective_date
),

account_dedup as (
    select distinct on (account_rk)
        account_rk,
        currency_cd,
        department_rk,
        effective_from_date,
        effective_to_date
    from rd.account
    order by account_rk, effective_from_date desc
),

currency_dedup as (
    select distinct on (currency_cd)
        currency_cd,
        currency_name,
        effective_from_date,
        effective_to_date
    from dm.dict_currency
    order by currency_cd, effective_from_date desc
),

balance_fixed as (
    select
        ab.account_rk,
        ab.effective_date,
        ab.account_in_sum  as original_in_sum,
        ab.account_out_sum as original_out_sum,

        -- lead смотрит на следующий день.
        -- для последнего дня счёта lead = null —
        -- оставим исходный account_out_sum.
        lead(ab.account_in_sum) over (
            partition by ab.account_rk
            order by ab.effective_date
        ) as next_in_sum

    from balance_dedup ab
)

select
    a.account_rk,
    coalesce(dc.currency_name, '-1'::text) as currency_name,
    a.department_rk,
    bf.effective_date,
    bf.original_in_sum as account_in_sum,

    -- корректный account_out_sum:
    -- если есть следующий день — берём его account_in_sum,
    -- если последний день счёта (lead = null) — оставляем исходный.
    coalesce(bf.next_in_sum, bf.original_out_sum) as account_out_sum

from balance_fixed bf
left join account_dedup a
       on a.account_rk = bf.account_rk
      and bf.effective_date between a.effective_from_date and a.effective_to_date
left join currency_dedup dc
       on dc.currency_cd = a.currency_cd
      and bf.effective_date between dc.effective_from_date and dc.effective_to_date
where a.department_rk is not null
order by a.account_rk, bf.effective_date;



-- 3 исправляет account_in_sum прямо в таблице rd.account_balance по логике задания 1.

with

-- дедуплицируем перед lag — иначе lag смотрит на дубль той же даты
balance_dedup as (
    select distinct on (account_rk, effective_date)
        account_rk,
        effective_date,
        account_in_sum,
        account_out_sum
    from rd.account_balance
    where effective_date is not null
    order by account_rk, effective_date
),

corrected as (
    select
        account_rk,
        effective_date,
        lag(account_out_sum) over (
            partition by account_rk
            order by effective_date
        ) as correct_in_sum
    from balance_dedup
)

update rd.account_balance as target
   set account_in_sum = c.correct_in_sum
  from corrected c
 where target.account_rk     = c.account_rk
   and target.effective_date = c.effective_date
   and c.correct_in_sum is not null
   and target.account_in_sum is distinct from c.correct_in_sum;


-- проверка после update

select *
from (
    select
        account_rk,
        effective_date,
        account_in_sum,
        lag(account_out_sum) over (
            partition by account_rk
            order by effective_date
        ) as prev_out_sum
    from (
        select distinct on (account_rk, effective_date)
            account_rk,
            effective_date,
            account_in_sum,
            account_out_sum
        from rd.account_balance
        where effective_date is not null
        order by account_rk, effective_date
    ) dedup
) t
where t.prev_out_sum is not null
  and t.account_in_sum is distinct from t.prev_out_sum;


-- 4 процедура полной перезагрузки витрины dm.account_balance_turnover.
-- написана по аналогии с dm.fill_loan_holiday_info (задание 2.2).


create or replace procedure dm.load_account_balance_turnover()
language plpgsql
as $$
declare
    v_log_id  integer;                                    -- id записи в логе
    v_rows    integer;                                    -- количество загруженных строк
    v_process varchar := 'dm.account_balance_turnover';   -- имя процесса
begin

    -- логируем старт процедуры
    insert into logs.etl_log (process_name, start_time, status)
    values (v_process, now(), 'started')
    returning log_id into v_log_id;

    -- шаг 1: полностью очищаем витрину
    truncate table dm.account_balance_turnover;

    -- шаг 2: заполняем витрину.
    -- в каждом cte — дедупликация источника через distinct on,

    insert into dm.account_balance_turnover (
        account_rk,
        currency_name,
        department_rk,
        effective_date,
        account_in_sum,
        account_out_sum
    )
    with

    balance_dedup as (
        -- дедупликация: одна запись баланса на (account_rk, effective_date)
        select distinct on (account_rk, effective_date)
            account_rk,
            effective_date,
            account_in_sum,
            account_out_sum
        from rd.account_balance
        where effective_date is not null
        order by account_rk, effective_date
    ),

    account_dedup as (
        -- дедупликация: одна версия счёта на account_rk
        select distinct on (account_rk)
            account_rk,
            currency_cd,
            department_rk,
            effective_from_date,
            effective_to_date
        from rd.account
        order by account_rk, effective_from_date desc
    ),

    currency_dedup as (
        -- дедупликация: одна запись валюты на currency_cd
        select distinct on (currency_cd)
            currency_cd,
            currency_name,
            effective_from_date,
            effective_to_date
        from dm.dict_currency
        order by currency_cd, effective_from_date desc
    ),

    balance_fixed as (
        -- считаем корректный account_in_sum через lag:
        -- берём account_out_sum предыдущего дня того же счёта.
        -- для первого дня счёта lag = null — оставляем исходный account_in_sum.
        select
            account_rk,
            effective_date,
            account_out_sum,
            coalesce(
                lag(account_out_sum) over (
                    partition by account_rk
                    order by effective_date
                ),
                account_in_sum
            ) as account_in_sum
        from balance_dedup
    )

    select
        a.account_rk,
        coalesce(dc.currency_name, '-1'::text) as currency_name,
        a.department_rk,
        bf.effective_date,
        bf.account_in_sum,
        bf.account_out_sum
    from balance_fixed bf
    left join account_dedup a
           on a.account_rk = bf.account_rk
          and bf.effective_date between a.effective_from_date and a.effective_to_date
    left join currency_dedup dc
           on dc.currency_cd = a.currency_cd
          and bf.effective_date between dc.effective_from_date and dc.effective_to_date

    -- department_rk в витрине not null — строки без счёта отсекаем
    where a.department_rk is not null;

    -- считаем сколько строк загружено
    get diagnostics v_rows = row_count;

    -- логируем успешное завершение
    update logs.etl_log
    set end_time    = now(),
        status      = 'success',
        rows_loaded = v_rows
    where log_id = v_log_id;

    raise notice 'витрина dm.account_balance_turnover перегружена. строк: %', v_rows;

exception
    when others then

        -- логируем ошибку
        update logs.etl_log
        set end_time      = now(),
            status        = 'error',
            error_message = sqlerrm
        where log_id = v_log_id;

        raise exception 'ошибка при перегрузке витрины: %', sqlerrm;
end;
$$;


-- запуск
call dm.load_account_balance_turnover();


-- проверка лога
select
    log_id,
    process_name,
    start_time,
    end_time,
    status,
    rows_loaded,
    error_message
from logs.etl_log
where process_name = 'dm.account_balance_turnover'
order by log_id;

-- проверяем что дублей нет
select account_rk, effective_date, count(*)
from dm.account_balance_turnover
group by account_rk, effective_date
having count(*) > 1;


-- проверка витрины
select count(*)
from dm.account_balance_turnover;