from functions import load_table, get_connection, transform_currency

if __name__ == '__main__':

    print("-" * 50)
    print("ETL-ПРОЦЕСС ЗАПУЩЕН")
    print("-" * 50)

    conn = get_connection()

    try:
        load_table(conn,
                   filename      ='ft_balance_f.csv',
                   table_name    = 'ft_balance_f',
                   schema        = 'ds',
                   encoding      = 'utf-8',
                   date_cols     = ['on_date'],
                   date_formats  = {'on_date': '%d.%m.%Y'},
                   conflict_cols = ['on_date', 'account_rk']
                   )
        load_table(conn,
                   filename      ='ft_posting_f.csv',
                   table_name    = 'ft_posting_f',
                   schema        = 'ds',
                   encoding      = 'utf-8',
                   date_cols     = ['oper_date'],
                   date_formats  = {'oper_date': '%d-%m-%Y'},
                   conflict_cols = None,
                   truncate      = True
                   )
        load_table(conn,
                   filename      ='md_account_d.csv',
                   table_name    = 'md_account_d',
                   schema        = 'ds',
                   encoding      = 'utf-8',
                   date_cols     = ['data_actual_date', 'data_actual_end_date'],
                   date_formats  = {},
                   conflict_cols = ['data_actual_date', 'account_rk']
                   )
        load_table(conn,
                   filename         ='md_currency_d.csv',
                   table_name       = 'md_currency_d',
                   schema           = 'ds',
                   encoding         = 'latin1',
                   date_cols        = ['data_actual_date', 'data_actual_end_date'],
                   date_formats     = {},
                   conflict_cols    = ['currency_rk', 'data_actual_date'],
                   extra_transform  = transform_currency
                   )
        load_table(conn,
                   filename      ='md_exchange_rate_d.csv',
                   table_name    = 'md_exchange_rate_d',
                   schema        = 'ds',
                   encoding      = 'latin1',
                   date_cols     = ['data_actual_date', 'data_actual_end_date'],
                   date_formats  = {},
                   conflict_cols = ['data_actual_date', 'currency_rk']
                   )
        load_table(conn,
                   filename      ='md_ledger_account_s.csv',
                   table_name    = 'md_ledger_account_s',
                   schema        = 'ds',
                   encoding      = 'utf-8',
                   date_cols     = ['start_date', 'end_date'],
                   date_formats  = {},
                   conflict_cols = ['ledger_account', 'start_date']
                   )
    finally:
        conn.close()

    print("-" * 50)
    print("ВСЕ ТАБЛИЦЫ ЗАГРУЖЕНЫ")
    print("-" * 50)