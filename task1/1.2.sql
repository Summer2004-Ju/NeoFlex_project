create schema dm;

create table DM.DM_ACCOUNT_TURNOVER_F (
	on_date				DATE,
	account_rk			numeric,
	credit_amount		numeric(23,8),
	credit_amount_rub	numeric(23,8),
	debet_amount		numeric(23,8),
	debet_amount_rub	numeric(23,8)
);

create table DM.DM_ACCOUNT_BALANCE_F (
	on_date			date,
	account_rk		numeric,
	balance_out		numeric(23,8),
	balance_out_rub	numeric(23,8)
);


insert into DM.DM_ACCOUNT_BALANCE_F (on_date, account_rk, balance_out, balance_out_rub)
select
    b.on_date,
    b.account_rk,
    b.balance_out,
    b.balance_out * coalesce(e.reduced_cource, 1) as balance_out_rub
from ds.ft_balance_f b
left join ds.md_account_d a
    on a.account_rk = b.account_rk
    and a.data_actual_date <= b.on_date
    and a.data_actual_end_date >= b.on_date
left join ds.md_exchange_rate_d e
    on e.currency_rk = a.currency_rk
    and e.data_actual_date <= b.on_date
    and e.data_actual_end_date >= b.on_date
where b.on_date = '2017-12-31';



--процедуру расчёта витрины оборотов

create or replace procedure ds.fill_account_turnover_f(i_OnDate date)
language plpgsql
as $$
declare
    v_log_id bigint;
    v_rows   integer;
begin
	--логируем старт
    insert into logs.etl_log (process_name, start_time, status)
    values ('ds.fill_account_turnover_f for ' || i_OnDate::text,
            clock_timestamp(), 'STARTED')
    returning log_id into v_log_id;

    delete from dm.dm_account_turnover_f where on_date = i_OnDate;

    insert into dm.dm_account_turnover_f
        (on_date, account_rk,
         credit_amount, credit_amount_rub,
         debet_amount,  debet_amount_rub)
    select
        i_OnDate,
        t.account_rk,
        t.credit_amount,
        t.credit_amount * coalesce(e.reduced_cource, 1),
        t.debet_amount,
        t.debet_amount  * coalesce(e.reduced_cource, 1)
    from (
        select account_rk,
               sum(credit_amount) as credit_amount,
               sum(debet_amount)  as debet_amount
        from (
            select credit_account_rk as account_rk,
                   credit_amount,
                   0::numeric         as debet_amount
            from   ds.ft_posting_f
            where  oper_date = i_OnDate
            union all
            select debet_account_rk,
                   0::numeric,
                   debet_amount
            from   ds.ft_posting_f
            where  oper_date = i_OnDate
        ) u
        group by account_rk
    ) t
    left join ds.md_account_d a
           on a.account_rk = t.account_rk
          and i_OnDate between a.data_actual_date and a.data_actual_end_date
    left join ds.md_exchange_rate_d e
           on e.currency_rk = a.currency_rk
          and i_OnDate between e.data_actual_date and e.data_actual_end_date;

    get diagnostics v_rows = row_count;

	--логируем финиш
    update logs.etl_log
    set end_time    = clock_timestamp(),
        status      = 'SUCCESS',
        rows_loaded = v_rows
    where log_id = v_log_id;
end;
$$;



--процедуру расчёта витрины остатков

create or replace procedure ds.fill_account_balance_f(i_OnDate date)
language plpgsql
as $$
declare
    v_log_id bigint;
    v_rows   integer;
begin
	--логируем старт 
    insert into logs.etl_log (process_name, start_time, status)
    values ('ds.fill_account_balance_f for ' || i_OnDate::text,
            clock_timestamp(), 'STARTED')
    returning log_id into v_log_id;

    delete from dm.dm_account_balance_f where on_date = i_OnDate;

    insert into dm.dm_account_balance_f (on_date, account_rk, balance_out, balance_out_rub)
    select i_OnDate,
           a.account_rk,
           case a.char_type
               when 'А' then coalesce(pb.balance_out, 0)
                             + coalesce(t.debet_amount, 0)
                             - coalesce(t.credit_amount, 0)
               when 'П' then coalesce(pb.balance_out, 0)
                             - coalesce(t.debet_amount, 0)
                             + coalesce(t.credit_amount, 0)
           end,
           case a.char_type
               when 'А' then coalesce(pb.balance_out_rub, 0)
                             + coalesce(t.debet_amount_rub, 0)
                             - coalesce(t.credit_amount_rub, 0)
               when 'П' then coalesce(pb.balance_out_rub, 0)
                             - coalesce(t.debet_amount_rub, 0)
                             + coalesce(t.credit_amount_rub, 0)
           end
    from       ds.md_account_d a
    left join  dm.dm_account_balance_f pb
           on pb.account_rk = a.account_rk
          and pb.on_date    = i_OnDate - interval '1 day'
    left join  dm.dm_account_turnover_f t
           on t.account_rk = a.account_rk
          and t.on_date    = i_OnDate
    where  i_OnDate between a.data_actual_date and a.data_actual_end_date;

    get diagnostics v_rows = row_count;

	--логируем финиш
    update logs.etl_log
    set end_time    = clock_timestamp(),
        status      = 'SUCCESS',
        rows_loaded = v_rows
    where log_id = v_log_id;
end;
$$;

-- рассчет витрин за весь январь 2018

do $$
declare d date;
begin
    for d in
        select generate_series('2018-01-01'::date,
                               '2018-01-31'::date,
                               '1 day')::date
    loop
        call ds.fill_account_turnover_f(d);
        call ds.fill_account_balance_f(d);
    end loop;
end $$;
