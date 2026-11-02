    select
        payment_method,
        sum(amount) as revenue
    from {{ ref('payments_eph') }}
    group by payment_method
