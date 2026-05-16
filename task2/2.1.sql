--проверка на дубли
select 
    client_rk,
    effective_from_date,
    count(*) as count
from dm.client
group by client_rk, effective_from_date
having count(*) > 1;

--основной запрос
with dupli as (
    select 
        ctid,
        row_number() over (
            partition by client_rk, effective_from_date
        ) as rn
    from dm.client
)
delete from dm.client
where ctid in (
    select ctid 
    from dupli 
    where rn > 1
);

