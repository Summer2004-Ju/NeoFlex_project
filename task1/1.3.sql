create table dm.dm_f101_round_f (
    from_date         date,
    to_date           date,
    chapter           char(1),
    ledger_account    char(5),
    characteristic    char(1),
    balance_in_rub    numeric(23,8),
    balance_in_val    numeric(23,8),
    balance_in_total  numeric(23,8),
    turn_deb_rub      numeric(23,8),
    turn_deb_val      numeric(23,8),
    turn_deb_total    numeric(23,8),
    turn_cre_rub      numeric(23,8),
    turn_cre_val      numeric(23,8),
    turn_cre_total    numeric(23,8),
    balance_out_rub   numeric(23,8),
    balance_out_val   numeric(23,8),
    balance_out_total numeric(23,8)
);

-- процедура dm.fill_f101_round_f

create or replace procedure dm.fill_f101_round_f(i_OnDate date)
language plpgsql
as $$
declare
    v_log_id    bigint;
    v_rows      integer;
    v_from_date date := i_OnDate - interval '1 month';
    v_to_date   date := i_OnDate - interval '1 day';
    v_prev_date date := v_from_date - interval '1 day';
begin
	--логирование старта
    insert into logs.etl_log (process_name, start_time, status)
    values ('dm.fill_f101_round_f for ' || i_OnDate::text,
            clock_timestamp(), 'STARTED')
    returning log_id into v_log_id;
delete from dm.dm_f101_round_f where from_date = v_from_date;
	
    
	--счета, действующие в отчетном периоде
    with
    acc as (
        select distinct                                          
               a.account_rk,
               left(a.account_number::text, 5) as ledger_account, 
               a.char_type                     as characteristic, --А или П
               ls.chapter,
               a.currency_code in ('810','643') as is_rub
        from   ds.md_account_d a
        left   join ds.md_ledger_account_s ls                
               on ls.ledger_account = left(a.account_number::text, 5)::integer
              and v_to_date between ls.start_date
                              and coalesce(ls.end_date, '9999-12-31'::date)
        where  a.data_actual_date <= v_to_date
          and  a.data_actual_end_date >= v_from_date
    ),

	--входящие остатки
    bal_in as (
        select account_rk, balance_out_rub
        from   dm.dm_account_balance_f
        where  on_date = v_prev_date
    ),
	--исходящие остатки
    bal_out as (
        select account_rk, balance_out_rub
        from   dm.dm_account_balance_f
        where  on_date = v_to_date
    ),

	--обороты
    turnovers as (
        select account_rk,
               sum(debet_amount_rub)  as deb_rub,
               sum(credit_amount_rub) as cre_rub
        from   dm.dm_account_turnover_f
        where  on_date between v_from_date and v_to_date
        group  by account_rk
    )

    insert into dm.dm_f101_round_f (
        from_date, to_date, chapter, ledger_account, characteristic,
        balance_in_rub, balance_in_val, balance_in_total,
        turn_deb_rub, turn_deb_val, turn_deb_total,
        turn_cre_rub, turn_cre_val, turn_cre_total,
        balance_out_rub, balance_out_val, balance_out_total
    )
    select
        v_from_date,
        v_to_date,
        a.chapter,
        a.ledger_account,
        a.characteristic,

		--входящий остаток
        coalesce(sum(case when a.is_rub     then coalesce(bi.balance_out_rub, 0) end), 0),
        coalesce(sum(case when not a.is_rub then coalesce(bi.balance_out_rub, 0) end), 0),
        coalesce(sum(coalesce(bi.balance_out_rub, 0)), 0),

		--дебетовые обороты
        coalesce(sum(case when a.is_rub     then coalesce(t.deb_rub, 0) end), 0),
        coalesce(sum(case when not a.is_rub then coalesce(t.deb_rub, 0) end), 0),
        coalesce(sum(coalesce(t.deb_rub, 0)), 0),

		--кредитовые обороты
        coalesce(sum(case when a.is_rub     then coalesce(t.cre_rub, 0) end), 0),
        coalesce(sum(case when not a.is_rub then coalesce(t.cre_rub, 0) end), 0),
        coalesce(sum(coalesce(t.cre_rub, 0)), 0),

		--исходящий остаток
        coalesce(sum(case when a.is_rub     then coalesce(bo.balance_out_rub, 0) end), 0),
        coalesce(sum(case when not a.is_rub then coalesce(bo.balance_out_rub, 0) end), 0),
        coalesce(sum(coalesce(bo.balance_out_rub, 0)), 0)

    from      acc a
    left join bal_in    bi on bi.account_rk = a.account_rk
    left join bal_out   bo on bo.account_rk = a.account_rk
    left join turnovers t  on t.account_rk  = a.account_rk

    group by a.chapter, a.ledger_account, a.characteristic;

    get diagnostics v_rows = row_count;

    update logs.etl_log
    set end_time    = clock_timestamp(),
        status      = 'SUCCESS',
        rows_loaded = v_rows
    where log_id = v_log_id;
end;
$$;




--вызов за январь 2018

call dm.fill_f101_round_f('2018-02-01');


