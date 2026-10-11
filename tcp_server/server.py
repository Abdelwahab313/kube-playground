import socket

server_socket = socket.socket(
    socket.AF_INET,
    socket.SOCK_STREAM,
    proto=0
)

print("server_socket type:", type(server_socket))
print("Server File Descriptor:", server_socket.fileno())

server_socket.bind(('0.0.0.0', 6543))
print("Server bound to 0.0.0.0", server_socket.getsockname())

backlog = 10
server_socket.listen(backlog)

print("Listening with backlog:", backlog)

while True:
    client_socket, addr = server_socket.accept()
    print("Accepted connection from", addr)
    data = client_socket.recv(1024)
    print("Received data:", data)
    client_socket.sendall(data)
    client_socket.close()
