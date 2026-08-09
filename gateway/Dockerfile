FROM python:3.14-slim

WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY starly_gateway.py ./

ENV STARLY_GATEWAY_HOST=0.0.0.0
ENV STARLY_GATEWAY_PORT=8780
ENV STARLY_GATEWAY_DATA=/data
VOLUME ["/data"]
EXPOSE 8780

CMD ["python", "starly_gateway.py"]
