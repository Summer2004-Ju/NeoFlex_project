--Анализ витрины dm.loan_holiday_info

-- сколько строк в витрине 
select count(*) from dm.loan_holiday_info; 

-- какие уникальные даты начала есть в витрине 
select distinct effective_from_date 
from dm.loan_holiday_info 
order by effective_from_date; 

-- какие уникальные даты окончания есть в витрине 
select distinct effective_to_date 
from dm.loan_holiday_info 
order by effective_to_date; 



-- сколько строк в источнике сделок 
select count(*) from rd.deal_info; 

-- какие даты начала периода есть в rd.deal_info 
select distinct effective_from_date 
from rd.deal_info 
order by effective_from_date; 

-- какие даты окончания периода есть в rd.deal_info 
select distinct effective_to_date 
from rd.deal_info 
order by effective_to_date; 


-- даты из витрины которых нет в rd.deal_info 
select distinct effective_from_date 
from dm.loan_holiday_info 
where effective_from_date not in ( 
    select distinct effective_from_date 
    from rd.deal_info 
) 
order by effective_from_date;

-- сколько строк в rd.loan_holiday 
select count(*) from rd.loan_holiday; 

 -- какие даты есть в rd.loan_holiday 
select distinct effective_from_date 
from rd.loan_holiday 
order by effective_from_date;


-- даты из витрины которых нет в rd.loan_holiday 
select distinct effective_from_date 
from dm.loan_holiday_info 
where effective_from_date not in ( 
    select distinct effective_from_date 
    from rd.loan_holiday 
) 
order by effective_from_date; 

-- сколько строк в rd.product 
select count(*) from rd.product; 

 -- какие даты есть в rd.product 
select distinct effective_from_date 
from rd.product 
order by effective_from_date; 


-- есть ли в витрине продукты которых нет в rd.product 
select distinct product_rk, product_name 
from dm.loan_holiday_info 
where product_rk not in ( 
    select distinct product_rk from rd.product 
) 
order by product_rk; 

-- дубли в rd.deal_info 
select deal_rk, effective_from_date, count(*) as cnt 
from rd.deal_info 
group by deal_rk, effective_from_date 
having count(*) > 1 
order by cnt desc; 

 -- дубли в rd.loan_holiday 
select deal_rk, effective_from_date, count(*) as cnt 
from rd.loan_holiday 
group by deal_rk, effective_from_date 
having count(*) > 1 
order by cnt desc; 

 -- дубли в rd.product
select product_rk, effective_from_date, count(*) as cnt 
from rd.product 
group by product_rk, effective_from_date 
having count(*) > 1 
order by cnt desc; 

--проверяем ограничения
select constraint_name, constraint_type 
from information_schema.table_constraints 
where table_schema = 'rd' 
and table_name = 'deal_info'; 

--удаляем дубли
with duplicates as (
    select
        ctid,
        row_number() over (
            partition by deal_rk, effective_from_date
            order by ctid
        ) as rn
    from rd.deal_info
)
delete from rd.deal_info
where ctid in (
    select ctid from duplicates where rn > 1
);

--добавляем первичный ключ
alter table rd.deal_info
add constraint deal_info_pk primary key (deal_rk, effective_from_date);

-- создаём схему для логов
create schema if not exists logs;

-- создаём таблицу логов etl-процесса.
-- if not exists — если таблица уже есть, команда пропустится без ошибки.
create table logs.etl_log (
    log_id        serial primary key,   
    process_name  varchar(100) not null, 
    start_time    timestamp,             
    end_time      timestamp,            
    status        varchar(50),           
    rows_loaded   integer,               
    error_message text                  
);



-- Процедура перегрузки витрины dm.loan_holiday_info

create or replace procedure dm.fill_loan_holiday_info()
language plpgsql
as $$
declare
    v_log_id  integer;
    v_rows    integer;
    v_process varchar := 'dm.loan_holiday_info';
begin
    -- логируем старт
    insert into logs.etl_log (process_name, start_time, status)
    values (v_process, now(), 'started')
    returning log_id into v_log_id;

    -- шаг 1: полностью очищаем витрину
    truncate table dm.loan_holiday_info;

    -- шаг 2: заполняем витрину строго по прототипу
    insert into dm.loan_holiday_info (
        deal_rk,
        effective_from_date,
        effective_to_date,
        agreement_rk,
        client_rk,
        department_rk,
        product_rk,
        product_name,
        deal_type_cd,
        deal_start_date,
        deal_name,
        deal_number,
        deal_sum,
        loan_holiday_type_cd,
        loan_holiday_start_date,
        loan_holiday_finish_date,
        loan_holiday_fact_finish_date,
        loan_holiday_finish_flg,
        loan_holiday_last_possible_date
    )

    with deal as (
        -- дедупликация: одна версия сделки за период
        select distinct on (deal_rk, effective_from_date)
            deal_rk,
            deal_num,
            deal_name,
            deal_sum,
            client_rk,
            agreement_rk,
            deal_start_date,
            department_rk,
            product_rk,
            deal_type_cd,
            effective_from_date,
            effective_to_date
        from rd.deal_info
        order by deal_rk, effective_from_date
    ),
    loan_holiday as (
        -- дедупликация: одна запись каникул по сделке за период
        select distinct on (deal_rk, effective_from_date)
            deal_rk,
            loan_holiday_type_cd,
            loan_holiday_start_date,
            loan_holiday_finish_date,
            loan_holiday_fact_finish_date,
            loan_holiday_finish_flg,
            loan_holiday_last_possible_date,
            effective_from_date,
            effective_to_date
        from rd.loan_holiday
        order by deal_rk, effective_from_date
    ),
    product as (
        -- дедупликация: одно название продукта за период
        select distinct on (product_rk, effective_from_date)
            product_rk,
            product_name,
            effective_from_date,
            effective_to_date
        from rd.product
        order by product_rk, effective_from_date
    ),
    holiday_info as (
        select
            d.deal_rk,
            lh.effective_from_date,
            lh.effective_to_date,
            d.deal_num as deal_number,
            lh.loan_holiday_type_cd,
            lh.loan_holiday_start_date,
            lh.loan_holiday_finish_date,
            lh.loan_holiday_fact_finish_date,
            lh.loan_holiday_finish_flg,
            lh.loan_holiday_last_possible_date,
            d.deal_name,
            d.deal_sum,
            d.client_rk,
            d.agreement_rk,
            d.deal_start_date,
            d.department_rk,
            d.product_rk,
            p.product_name,
            d.deal_type_cd
        from deal d
        left join loan_holiday lh
            on d.deal_rk = lh.deal_rk
           and d.effective_from_date = lh.effective_from_date
        left join product p
            on p.product_rk = d.product_rk
           and p.effective_from_date = d.effective_from_date
    )
    select
        deal_rk,
        effective_from_date,
        effective_to_date,
        agreement_rk,
        client_rk,
        department_rk,
        product_rk,
        product_name,
        deal_type_cd,
        deal_start_date,
        deal_name,
        deal_number,
        deal_sum,
        loan_holiday_type_cd,
        loan_holiday_start_date,
        loan_holiday_finish_date,
        loan_holiday_fact_finish_date,
        loan_holiday_finish_flg,
        loan_holiday_last_possible_date
    from holiday_info;

    -- считаем сколько строк загружено
    get diagnostics v_rows = row_count;

    -- логируем успешное завершение
    update logs.etl_log
    set end_time    = now(),
        status      = 'success',
        rows_loaded = v_rows
    where log_id = v_log_id;

    raise notice 'Витрина dm.loan_holiday_info перегружена. Строк: %', v_rows;

exception
    when others then
        -- логируем ошибку
        update logs.etl_log
        set end_time      = now(),
            status        = 'error',
            error_message = sqlerrm
        where log_id = v_log_id;

        raise exception 'Ошибка при перегрузке витрины: %', sqlerrm;
end;
$$;

--вызов процедуры
call dm.fill_loan_holiday_info();

-- количество строк в витрине
select count(*) from dm.loan_holiday_info;

-- проверяем периоды
select distinct effective_from_date
from dm.loan_holiday_info
order by effective_from_date;

