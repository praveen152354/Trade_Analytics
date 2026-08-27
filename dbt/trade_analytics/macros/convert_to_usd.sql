{% macro convert_to_usd(amount_column, currency_column) %}
{#-
    Generates a CASE expression converting amount_column (in currency_column)
    to USD, using the fx_rates_to_usd var in dbt_project.yml as the single
    source of truth for rates.

    This is the payoff of doing it as a macro rather than hand-written SQL:
    every model that needs a USD amount calls one line --
        {{ convert_to_usd('notional', 'currency') }} as notional_usd
    -- and adding a currency, or repricing an existing one, is a one-line
    change in dbt_project.yml that takes effect everywhere the macro is used,
    with no SQL edits and no risk of one call site drifting out of sync with
    another.
-#}
    case {{ currency_column }}
    {%- for currency_code, rate_to_usd in var('fx_rates_to_usd').items() %}
        when '{{ currency_code }}' then {{ amount_column }} * {{ rate_to_usd }}
    {%- endfor %}
        else null
    end
{% endmacro %}
