-- 1. Запрос определяет корректное значение поля account_in_sum.
-- Правило: если account_in_sum текущего дня отличается от
-- account_out_sum предыдущего дня — корректным считается
-- account_out_sum предыдущего дня.


with balance_fixed as (
    select
        ab.account_rk,
        ab.effective_date,
        ab.account_in_sum  as original_in_sum,
        ab.account_out_sum as original_out_sum,
        -- lag смотрит на предыдущую строку того же счёта по дате.
        -- для первого дня счёта вернёт null — предыдущего дня нет.
        lag(ab.account_out_sum) over (
            partition by ab.account_rk
            order by ab.effective_date
        ) as prev_out_sum
    from rd.account_balance ab
)
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
left join rd.account a
       on a.account_rk = bf.account_rk
      and bf.effective_date between a.effective_from_date and a.effective_to_date
left join dm.dict_currency dc
       on dc.currency_cd = a.currency_cd
      and bf.effective_date between dc.effective_from_date and dc.effective_to_date
where a.department_rk is not null
order by a.account_rk, bf.effective_date;




-- 2. Запрос определяет корректное значение поля account_out_sum.
-- Правило обратное: account_in_sum текущего дня правильный,
-- а account_out_sum предыдущего дня некорректен.
-- Корректным считается account_in_sum следующего дня (через LEAD).


with balance_fixed as (
    select
        ab.account_rk,
        ab.effective_date,
        ab.account_in_sum  as original_in_sum,
        ab.account_out_sum as original_out_sum,
        -- lead смотрит на следующую строку того же счёта по дате.
        -- для последнего дня счёта вернёт null — следующего дня нет.
        lead(ab.account_in_sum) over (
            partition by ab.account_rk
            order by ab.effective_date
        ) as next_in_sum
    from rd.account_balance ab
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
left join rd.account a
       on a.account_rk = bf.account_rk
      and bf.effective_date between a.effective_from_date and a.effective_to_date
left join dm.dict_currency dc
       on dc.currency_cd = a.currency_cd
      and bf.effective_date between dc.effective_from_date and dc.effective_to_date
where a.department_rk is not null
order by a.account_rk, bf.effective_date;




-- 3. Исправляет account_in_sum прямо в таблице rd.account_balance по логике задания 1.


-- основной update
with corrected as (
    select
        account_rk,
        effective_date,
        -- вычисляем правильный account_in_sum через lag
        lag(account_out_sum) over (
            partition by account_rk
            order by effective_date
        ) as correct_in_sum
    from rd.account_balance
)
update rd.account_balance as target
   set account_in_sum = c.correct_in_sum
  from corrected c
 where target.account_rk     = c.account_rk      -- связываем по счёту
   and target.effective_date = c.effective_date   -- и по дате
   and c.correct_in_sum is not null               -- пропускаем первый день счёта
   and target.account_in_sum is distinct from c.correct_in_sum; -- только расхождения


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
    from rd.account_balance
) t
where t.prev_out_sum is not null
  and t.account_in_sum is distinct from t.prev_out_sum;




-- 4. Процедура полной перезагрузки витрины dm.account_balance_turnover.
-- По аналогии с dm.fill_loan_holiday_info (задание 2.2).


create or replace procedure dm.load_account_balance_turnover()
language plpgsql
as $$
declare
    v_log_id  integer;                                   -- id записи в логе
    v_rows    integer;                                   -- количество загруженных строк
    v_process varchar := 'DM.ACCOUNT_BALANCE_TURNOVER'; -- имя процесса
begin

    -- логируем старт процедуры
    insert into logs.etl_log (process_name, start_time, status)
    values (v_process, now(), 'STARTED')
    returning log_id into v_log_id;

    -- шаг 1: полностью очищаем витрину
    truncate table dm.account_balance_turnover;

    -- шаг 2: заполняем витрину с исправленным account_in_sum
    insert into dm.account_balance_turnover (
        account_rk,
        currency_name,
        department_rk,
        effective_date,
        account_in_sum,
        account_out_sum
    )
    with balance_fixed as (
        select
            account_rk,
            effective_date,
            account_out_sum,
            -- исправляем account_in_sum через lag:
            -- берём account_out_sum предыдущего дня того же счёта.
            -- coalesce: если lag = null (первый день) — оставляем исходный.
            coalesce(
                lag(account_out_sum) over (
                    partition by account_rk
                    order by effective_date
                ),
                account_in_sum
            ) as account_in_sum
        from rd.account_balance
    )
    select
        a.account_rk,
        coalesce(dc.currency_name, '-1'::text) as currency_name,
        a.department_rk,
        bf.effective_date,
        bf.account_in_sum,
        bf.account_out_sum
    from balance_fixed bf
    left join rd.account a
           on a.account_rk = bf.account_rk
          and bf.effective_date between a.effective_from_date and a.effective_to_date
    left join dm.dict_currency dc
           on dc.currency_cd = a.currency_cd
          and bf.effective_date between dc.effective_from_date and dc.effective_to_date
    where a.department_rk is not null;

    -- считаем сколько строк загружено
    get diagnostics v_rows = row_count;

    -- логируем успешное завершение
    update logs.etl_log
    set end_time    = now(),
        status      = 'SUCCESS',
        rows_loaded = v_rows
    where log_id = v_log_id;

    raise notice 'Витрина dm.account_balance_turnover перегружена. Строк: %', v_rows;

exception
    when others then
        -- логируем ошибку
        update logs.etl_log
        set end_time      = now(),
            status        = 'ERROR',
            error_message = sqlerrm
        where log_id = v_log_id;

        raise exception 'Ошибка при перегрузке витрины: %', sqlerrm;
end;
$$;


-- запуск процедуры
call dm.load_account_balance_turnover();

-- проверка лога
select log_id, process_name, start_time, end_time,
       status, rows_loaded, error_message
from logs.etl_log
where process_name = 'DM.ACCOUNT_BALANCE_TURNOVER'
order by log_id desc;

-- проверка дублей в витрине 
select account_rk, effective_date, count(*)
from dm.account_balance_turnover
group by account_rk, effective_date
having count(*) > 1;

-- количество строк в витрине
select count(*) from dm.account_balance_turnover;

