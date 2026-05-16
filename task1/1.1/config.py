import os
from  dotenv import load_dotenv

# загружаем переменные из .env
load_dotenv()

# параметры подключения к БД
DB_CONFIG = {
    'host':     os.getenv('DB_HOST'),
    'port':     int(os.getenv('DB_PORT')),
    'dbname':   os.getenv('DB_NAME'),
    'user':     os.getenv('DB_USER'),
    'password': os.getenv('DB_PASSWORD')
}

# путь к папке с CSV-файлами
CSV_DIR = os.getenv('CSV_DIR')
