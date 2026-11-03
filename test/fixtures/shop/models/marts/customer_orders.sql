{{
    config(
        materialized='incremental',
        unique_key='customer_id'
    )
}}

select
    c.customer_id,
    c.first_name,
    count(o.order_id) as order_count,
    max(o.order_date) as last_order_date
from {{ ref('shop', 'stg_customers') }} as c
join {{ ref('orders') }} as o on o.customer_id = c.customer_id
{% if is_incremental() %}
where o.order_date >= (select coalesce(max(last_order_date), '1900-01-01') from {{ this }})
{% endif %}
group by c.customer_id, c.first_name
