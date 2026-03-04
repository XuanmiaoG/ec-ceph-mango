mkdir -p /users/gaoy31/download && \
cp *.csv /users/gaoy31/download/ && \
cd /users/gaoy31/download && \
tar -czvf csv_results.tar.gz *.csv

scp gaoy31@pc771.emulab.net:/users/gaoy31/download/csv_results.tar.gz ~/Desktop/