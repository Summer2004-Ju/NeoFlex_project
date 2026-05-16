from functions import load_table, get_connection

if __name__ == '__main__':

    print("-" * 50)
    print("ETL-ПРОЦЕСС ЗАПУЩЕН")
    print("-" * 50)

    conn = get_connection()

    try:
        # Метод: UPSERT — добавляем новые, существующие обновляем
        # conflict_cols = уникальный ключ: одна сделка за один период
        load_table(conn,
                   filename      = 'deal_info.csv',
                   table_name    = 'deal_info',
                   schema        = 'rd',
                   encoding      = 'cp1252',
                   date_cols     = ['deal_start_date', 'effective_from_date', 'effective_to_date'],
                   date_formats  = {},
                   conflict_cols = ['deal_rk', 'effective_from_date'],
                   sep           = ','
                   )

        # Метод: TRUNCATE + INSERT — полная перегрузка
        # conflict_cols = ключ для дедупликации CSV перед загрузкой
        load_table(conn,
                   filename      = 'product_info.csv',
                   table_name    = 'product',
                   schema        = 'rd',
                   encoding      = 'cp1252',
                   date_cols     = ['effective_from_date', 'effective_to_date'],
                   date_formats  = {},
                   conflict_cols = ['product_rk', 'effective_from_date'],
                   truncate      = True,
                   sep           = ','
                   )

    finally:
        conn.close()

    print("\n" + "-" * 50)
    print("ЗАГРУЗКА ЗАВЕРШЕНА")
    print("-" * 50)