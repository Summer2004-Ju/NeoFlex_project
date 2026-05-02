import os
import psycopg2
import pandas as pd
import csv
from psycopg2.extras import execute_values
from datetime import datetime
from dotenv import load_dotenv


# подключение к бд

load_dotenv()

DB_CONFIG = {
    'host':     os.getenv('DB_HOST'),
    'port':     int(os.getenv('DB_PORT')),
    'dbname':   os.getenv('DB_NAME'),
    'user':     os.getenv('DB_USER'),
    'password': os.getenv('DB_PASSWORD')
}

CSV_PATH = os.getenv('CSV_PATH')

# логирование
def log_start(conn, process_name):
    with conn.cursor() as cur:
        cur.execute("""
            insert into logs.etl_log (process_name, start_time, status)
            values (%s, %s, 'STARTED')
            returning log_id
        """, (process_name, datetime.now()))
        log_id = cur.fetchone()[0]
    conn.commit()
    return log_id


def log_end(conn, log_id, process_name, rows, status='SUCCESS', error_msg=None):
    with conn.cursor() as cur:
        cur.execute("""
            update logs.etl_log
            set end_time = %s, status = %s, rows_loaded = %s, error_message = %s
            where log_id = %s
        """, (datetime.now(), status, rows, error_msg, log_id))
    conn.commit()


# экспорт в csv
def export_f101():

    print("Экспорт: БД → CSV")
    conn = psycopg2.connect(**DB_CONFIG)
    log_id = log_start(conn, 'EXPORT dm.dm_f101_round_f → CSV')
    rows = 0
    
    try:
        with conn.cursor() as cur:
            cur.execute("""
                select * 
                from dm.dm_f101_round_f 
                order by ledger_account, characteristic
            """)
            
            # имена колонок
            columns = [desc[0] for desc in cur.description]
            print(f"Колонок: {len(columns)}")
            
            # открываем csv
            with open(CSV_PATH, 'w', newline='', encoding='utf-8') as f:
                writer = csv.writer(f, delimiter=';')
                
                # первая строка = заголовок
                writer.writerow(columns)
                
                # остальные строки = данные
                for row in cur:
                    writer.writerow(row)
                    rows += 1
        
        print(f"Файл: {CSV_PATH}")
        print(f"Строк: {rows}")
        log_end(conn, log_id, 'EXPORT dm.dm_f101_round_f → CSV', rows)
        print("Экспорт завершен")


    except Exception as e:
        log_end(conn, log_id, 'EXPORT dm.dm_f101_round_f → CSV', rows, 
                status='ERROR', error_msg=str(e))
        print(f"\nОШИБКА: {e}\n")
        raise
    
    finally:
        conn.close()


# импорт в бд измененного csv
def import_f101():
    print("Импорт: CSV → БД")
    conn = psycopg2.connect(**DB_CONFIG)
    log_id = log_start(conn, 'IMPORT CSV → dm.dm_f101_round_f_v2')
    rows = 0
    
    try:
        # читаем csv
        df = pd.read_csv(CSV_PATH, sep=';', encoding='utf-8')
        df.columns = [c.lower() for c in df.columns]
        print(f"Строк: {len(df)}")
        print(f"Колонок: {len(df.columns)}")
        
        # проверка колонок
        required = [
            'from_date', 'to_date', 'chapter', 'ledger_account', 'characteristic',
            'balance_in_rub', 'balance_in_val', 'balance_in_total',
            'turn_deb_rub', 'turn_deb_val', 'turn_deb_total',
            'turn_cre_rub', 'turn_cre_val', 'turn_cre_total',
            'balance_out_rub', 'balance_out_val', 'balance_out_total'
        ]
        
        missing = [c for c in required if c not in df.columns]
        if missing:
            raise ValueError(f"Отсутствуют: {missing}")
        
        print("Валидация ✓")
        
        # даты
        for col in ['from_date', 'to_date']:
            df[col] = pd.to_datetime(df[col]).dt.date
        print("Даты ✓")
        
        # NaN → None
        df = df.where(pd.notnull(df), None)
        
        # очищаем таблицу
        with conn.cursor() as cur:
            cur.execute("delete from dm.dm_f101_round_f_v2")
            conn.commit()
        print("Таблица очищена ✓")
        
        # вставка
        cols = list(df.columns)
        values = [tuple(row) for row in df.itertuples(index=False, name=None)]
        
        sql = f"""
            insert into dm.dm_f101_round_f_v2
                ({', '.join(cols)})
            values %s
        """
        
        print(f"Загружаю {len(values)} строк...")
        with conn.cursor() as cur:
            execute_values(cur, sql, values, page_size=500)
        conn.commit()
        
        rows = len(values)
        print(f"Загружено: {rows}")
        
        log_end(conn, log_id, 'IMPORT CSV → dm.dm_f101_round_f_v2', rows)

        print("Импорт завершен")
        print("\n")

    except Exception as e:
        log_end(conn, log_id, 'IMPORT CSV → dm.dm_f101_round_f_v2', rows,
                status='ERROR', error_msg=str(e))
        print(f"\nОШИБКА: {e}\n")
        raise
    
    finally:
        conn.close()

# запуск

if __name__ == '__main__':

    # 1 экспорт
    #export_f101()
    
    # 2 импорт
    import_f101()
