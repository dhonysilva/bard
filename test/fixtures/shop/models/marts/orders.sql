{%- set payment_methods = ['credit_card', 'coupon', 'bank_transfer'] -%}

with payments as (
    select * from {{ ref('payments_eph') }}
),

order_payments as (
    select
        order_id,
        {% for method in payment_methods -%}
        sum(case when payment_method = '{{ method }}' then amount else 0 end) as {{ method }}_amount
        {%- if not loop.last %},{% endif %}
        {% endfor %}
    from payments
    group by order_id
)

select
    o.order_id,
    o.customer_id,
    o.order_date,
    o.status,
    {% for method in payment_methods %}coalesce(p.{{ method }}_amount, 0) as {{ method }}_amount, {% endfor %}
    '{{ env_var("SHOP_REGION", "us") }}' as region
from {{ ref('stg_orders') }} as o
left join order_payments as p on p.order_id = o.order_id
{% if var('status_filter') != 'all' %}
where o.status = '{{ var("status_filter") }}'
{% endif %}
