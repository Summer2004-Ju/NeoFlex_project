import pandas as pd
import psycopg2
from psycopg2.extras import execute_values
from config import DB_CONFIG, CSV_DIR
import time
from datetime import datetime

def get_connection():
    return psycopg2.connect(**DB_CONFIG)


def log_start(conn, process_name):
    with conn.cursor() as cur:
        cur.execute("""
            INSERT INTO logs.etl_log (process_name, start_time, status)
            VALUES (%s, %s, 'STARTED')
            RETURNING log_id
        """, (process_name, datetime.now()))
        log_id = cur.fetchone()[0]
    conn.commit()
    print(f"СТАРТ: {process_name} в {datetime.now().strftime('%H:%M:%S')}")
    print("  Пауза 5 секунд...")
    time.sleep(5)
    return log_id


def log_end(conn, log_id, process_name, rows_loaded, status='SUCCESS', error_msg=None):
    with conn.cursor() as cur:
        cur.execute("""
            UPDATE logs.etl_log
            SET end_time = %s, status = %s, rows_loaded = %s, error_message = %s
            WHERE log_id = %s
        """, (datetime.now(), status, rows_loaded, error_msg, log_id))
    conn.commit()
    print(f"КОНЕЦ: {process_name} | Статус: {status} | Строк загружено: {rows_loaded}")


def check_duplicates(df, subset=None):
    before = len(df)
    df_clean = df.drop_duplicates(subset=subset, keep='last')
    dupes = before - len(df_clean)
    if dupes > 0:
        print(f"  Найдено и удалено дубликатов: {dupes}")
    else:
        print("  Дубликатов не найдено")
    return df_clean


def upsert(conn, df, schema, table, conflict_cols):
    """
    Добавляет новые строки / обновляет существующие (по conflict_cols).
    Используется когда нужно догрузить часть данных, не трогая остальные.
    Требует PRIMARY KEY или UNIQUE на conflict_cols.
    """
    if df.empty:
        return 0
    cols = list(df.columns)
    values = [tuple(row) for row in df.itertuples(index=False, name=None)]
    update_cols = [c for c in cols if c not in conflict_cols]
    update_set = ', '.join([f'"{c}" = EXCLUDED."{c}"' for c in update_cols])
    conflict_target = ', '.join([f'"{c}"' for c in conflict_cols])
    sql = f"""
        INSERT INTO {schema}.{table}
            ({', '.join([f'"{c}"' for c in cols])})
        VALUES %s
        ON CONFLICT ({conflict_target})
        DO UPDATE SET {update_set}
    """
    with conn.cursor() as cur:
        execute_values(cur, sql, values, page_size=500)
    conn.commit()
    return len(values)


def truncate_and_insert(conn, df, schema, table):
    """
    Полностью очищает таблицу и заливает данные заново.
    Используется когда CSV содержит полный актуальный срез данных.
    """
    if df.empty:
        return 0
    cols = list(df.columns)
    values = [tuple(row) for row in df.itertuples(index=False, name=None)]
    with conn.cursor() as cur:
        cur.execute(f'TRUNCATE TABLE {schema}.{table}')
        sql = f"""
            INSERT INTO {schema}.{table}
                ({', '.join([f'"{c}"' for c in cols])})
            VALUES %s
        """
        execute_values(cur, sql, values, page_size=500)
    conn.commit()
    return len(values)


def load_table(conn, filename, table_name, schema, encoding,
               date_cols, date_formats, conflict_cols,
               truncate=False, sep=','):
    process = f'{schema.upper()}.{table_name.upper()}'
    log_id = log_start(conn, process)
    rows = 0
    try:
        df = pd.read_csv(f'{CSV_DIR}/{filename}', sep=sep, encoding=encoding)
        df.columns = [c.lower() for c in df.columns]

        for col in date_cols:
            fmt = date_formats.get(col)
            if fmt:
                df[col] = pd.to_datetime(df[col], format=fmt).dt.date
            else:
                df[col] = pd.to_datetime(df[col]).dt.date

        df = check_duplicates(df, subset=conflict_cols)

        if truncate:
            rows = truncate_and_insert(conn, df, schema, table_name)
        else:
            rows = upsert(conn, df, schema, table_name, conflict_cols)

        log_end(conn, log_id, process, rows)

    except Exception as e:
        log_end(conn, log_id, process, rows, status='ERROR', error_msg=str(e))
        raise