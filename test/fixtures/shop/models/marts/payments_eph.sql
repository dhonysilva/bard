{{ config(materialized='ephemeral') }}

select order_id, payment_method, amount
from {{ ref('stg_payments') }}
where amount > {{ var('min_amount', 0) }}
