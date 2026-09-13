
import sys
import subprocess

try:
    import serial
    import serial.tools.list_ports
except ImportError:
    print("'pyserial' library not found. Attempting to install...")
    try:
        subprocess.check_call([sys.executable, "-m", "pip", "install", "pyserial"])
        print("\n'pyserial' has been successfully installed.")
        input("Please restart the program to continue. Press Enter to exit.")
        sys.exit()
    except Exception as e:
        print(f"\nError: Failed to install 'pyserial'. Please install it manually: pip install pyserial")
        input(f"Details: {e}\nPress Enter to exit.")
        sys.exit()

import tkinter as tk
from tkinter import ttk, scrolledtext, messagebox
import threading
from queue import Queue

DEFAULT_SERIAL_PORT = 'COM3' # 사용자 환경에 맞게 수정
BAUD_RATE = 115200

class ElevatorGUI(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("FPGA Elevator Control Panel")
        self.geometry("450x550")

        self.serial_connection = None
        self.read_thread = None
        self.queue = Queue()
        self.log_line_number = 1
        
        self.help_popup_on_cooldown = False

        self._create_widgets()
        self.protocol("WM_DELETE_WINDOW", self.on_closing)
        self.process_serial_queue()

    def _create_widgets(self):
        conn_frame = ttk.LabelFrame(self, text="Connection")
        conn_frame.pack(padx=10, pady=5, fill="x")
        ttk.Label(conn_frame, text="COM Port:").pack(side=tk.LEFT, padx=5)
        available_ports = [port.device for port in serial.tools.list_ports.comports()]
        self.port_combobox = ttk.Combobox(conn_frame, values=available_ports, width=10)
        if available_ports: self.port_combobox.set(available_ports[0])
        else: self.port_combobox.set("No ports")
        self.port_combobox.pack(side=tk.LEFT, padx=5, fill="x", expand=True)
        self.connect_button = ttk.Button(conn_frame, text="Connect", command=self.toggle_connection)
        self.connect_button.pack(side=tk.LEFT, padx=5)
        status_frame = ttk.LabelFrame(self, text="Elevator Status")
        status_frame.pack(padx=10, pady=5, fill="x")
        self.floor_label = ttk.Label(status_frame, text="Floor: --", font=("Helvetica", 36, "bold"))
        self.floor_label.pack(pady=10)
        self.dir_label = ttk.Label(status_frame, text="Direction: N/A", font=("Helvetica", 16))
        self.dir_label.pack(pady=5)
        control_frame = ttk.LabelFrame(self, text="Control")
        control_frame.pack(padx=10, pady=5, fill="x")
        ttk.Label(control_frame, text="Floor:").pack(side=tk.LEFT, padx=5)
        self.floor_input = ttk.Entry(control_frame, width=5)
        self.floor_input.pack(side=tk.LEFT, padx=5)
        ttk.Button(control_frame, text="▲ UP", command=lambda: self.send_command("UP")).pack(side=tk.LEFT, padx=2)
        ttk.Button(control_frame, text="▼ DOWN", command=lambda: self.send_command("DOWN")).pack(side=tk.LEFT, padx=2)
        ttk.Button(control_frame, text="Car Call", command=lambda: self.send_command("CAR")).pack(side=tk.LEFT, padx=2)
        log_frame = ttk.LabelFrame(self, text="Communication Log")
        log_frame.pack(padx=10, pady=5, fill="both", expand=True)
        self.log_text = scrolledtext.ScrolledText(log_frame, wrap=tk.WORD, height=10, state='disabled')
        self.log_text.pack(fill="both", expand=True)

    def toggle_connection(self):
        if self.serial_connection and self.serial_connection.is_open:
            self.serial_connection.close()
            self.log_message("Disconnected.")
            self.connect_button.config(text="Connect")
            self.floor_label.config(text="Floor: --")
            self.dir_label.config(text="Direction: N/A")
        else:
            port = self.port_combobox.get()
            try:
                self.serial_connection = serial.Serial(port, BAUD_RATE, timeout=1)
                self.log_message(f"Connected to {port}")
                self.connect_button.config(text="Disconnect")
                self.read_thread = threading.Thread(target=self.read_from_serial, daemon=True)
                self.read_thread.start()
            except serial.SerialException as e:
                self.log_message(f"Error: {e}")

    def send_command(self, cmd_type):
        floor_str = self.floor_input.get().strip()
        if not floor_str.isdigit():
            self.log_message("ERR:CMD")
            return
        if cmd_type == "UP": command = f"{floor_str}UP"
        elif cmd_type == "DOWN": command = f"{floor_str}DOWN"
        elif cmd_type == "CAR": command = f"C{floor_str}"
        else: return
        if self.serial_connection and self.serial_connection.is_open:
            full_command = command + '\r'
            self.serial_connection.write(full_command.encode('ascii'))
            self.log_message(f"Sent: {command}")
        else:
            self.log_message("Error: Not connected.")

    def read_from_serial(self):
        while self.serial_connection and self.serial_connection.is_open:
            try:
                line = self.serial_connection.readline().decode('ascii').strip()
                if line: self.queue.put(line)
            except (serial.SerialException, TypeError): break
    
    def process_serial_queue(self):
        try:
            while not self.queue.empty():
                message = self.queue.get_nowait()
                self.log_message(f"Rcvd: {message}")
                self.update_status(message)
        finally:
            self.after(100, self.process_serial_queue)

    def update_status(self, message):
        if message.startswith("F:"):
            try:
                parts = message.split(',')
                floor_part = parts[0].split(':')[1]
                dir_part = parts[1].split(':')[1]
                self.floor_label.config(text=f"Floor: {floor_part}")
                self.dir_label.config(text=f"Direction: {dir_part}")
            except IndexError: self.dir_label.config(text="Invalid Format")
        elif message.startswith("ERR:"):
            self.floor_label.config(text="Error")
            self.dir_label.config(text=message)
        elif message.startswith("HELP:"):
            if not self.help_popup_on_cooldown:
                self.help_popup_on_cooldown = True
                try:
                    help_text = message.split(':', 1)[1].strip()
                    messagebox.showinfo("Command Help", help_text)
                except IndexError:
                    messagebox.showinfo("Command Help", "No help text received.")
                
                self.after(1000, self.reset_help_cooldown)

    def reset_help_cooldown(self):
        """This function is called by the timer to reset the cooldown flag."""
        self.help_popup_on_cooldown = False
        self.log_message("Help popup cooldown reset.")

    def log_message(self, message):
        self.log_text.config(state='normal')
        formatted_message = f"[{self.log_line_number:03d}] {message}\n"
        self.log_text.insert(tk.END, formatted_message)
        self.log_text.see(tk.END)
        self.log_text.config(state='disabled')
        self.log_line_number += 1

    def on_closing(self):
        if self.serial_connection and self.serial_connection.is_open:
            self.serial_connection.close()
        self.destroy()

if __name__ == "__main__":
    app = ElevatorGUI()
    app.mainloop()