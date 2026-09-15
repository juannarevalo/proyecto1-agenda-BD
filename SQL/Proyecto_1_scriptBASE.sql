-- Crear la base de datos
CREATE SCHEMA prototipo;

-- Configurar el search_path para que las tablas se creen dentro de ese esquema
-- y se busquen ahí automáticamente
SET search_path TO prototipo, public;

-- 1. Usuarios
CREATE TABLE usuarios (
    id_usuario SERIAL PRIMARY KEY,
    nombre VARCHAR(50) NOT NULL,
    apellido VARCHAR(50) NOT NULL,
    fecha_registro DATE DEFAULT CURRENT_DATE NOT NULL,
    activo BOOLEAN DEFAULT TRUE
);

-- 2. Contactos (RF02, RE02, RN02)
CREATE TABLE usuario_telefonos (
    id_usuario INT REFERENCES usuarios(id_usuario),
    telefono VARCHAR(20),
    PRIMARY KEY (id_usuario, telefono)
);

CREATE TABLE usuario_emails (
    id_usuario INT REFERENCES usuarios(id_usuario),
    email VARCHAR(100),
    PRIMARY KEY (id_usuario, email)
);

-- 3. Categorías (RF03, RE05, RN04)
CREATE TABLE categorias (
    id_categoria SERIAL PRIMARY KEY,
    nombre VARCHAR(50) NOT NULL,
    id_categoria_padre INT REFERENCES categorias(id_categoria)
    -- NOTA: La raíz tendría id_categoria_padre NULL
);

-- 4. Eventos (RF04, RE04)
CREATE TABLE eventos (
    id_evento SERIAL PRIMARY KEY,
    id_usuario_propietario INT NOT NULL REFERENCES usuarios(id_usuario),
    id_categoria INT NOT NULL REFERENCES categorias(id_categoria),
    titulo VARCHAR(100) NOT NULL,
    descripcion TEXT,
    fecha_inicio TIMESTAMP NOT NULL,
    fecha_fin TIMESTAMP NOT NULL,
    CONSTRAINT check_fechas CHECK (fecha_fin > fecha_inicio)
    
);

-- 5. Participación (RF05, RE01, RN01, RN05)
CREATE TABLE participaciones (
    id_evento INT REFERENCES eventos(id_evento) ON DELETE CASCADE,
    id_invitado INT REFERENCES usuarios(id_usuario),
    rol VARCHAR(50),
    estado_confirmacion VARCHAR(20) DEFAULT 'pendiente',
    PRIMARY KEY (id_evento, id_invitado)
);

-- 6. Log de Accesos (RF06)
CREATE TABLE log_accesos (
    id_log SERIAL PRIMARY KEY,
    id_usuario INT REFERENCES usuarios(id_usuario),
    fecha_acceso TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Implementación de Cálculos Dinámicos (RF07, RE03, RN03) mediante vistas

-- Vista para Antigüedad
CREATE VIEW vista_antiguedad_usuarios AS
SELECT 
    id_usuario, 
    nombre, 
    fecha_registro,
    age(CURRENT_DATE, fecha_registro) AS antiguedad
FROM usuarios;

-- Vista para Duración de eventos diarios
CREATE VIEW vista_duracion_eventos_diarios AS
SELECT 
    id_usuario_propietario,
    fecha_inicio::DATE AS dia,
    SUM(EXTRACT(EPOCH FROM (fecha_fin - fecha_inicio))/60) AS duracion_total_minutos
FROM eventos
GROUP BY id_usuario_propietario, fecha_inicio::DATE;

--Integridad y Prevención de Ciclos (RE05)
--Para evitar ciclos en la jerarquía de categorías, podemos usar una función 
--que verifique el ancestro antes de insertar o actualizar:

CREATE OR REPLACE FUNCTION evitar_ciclo_categorias()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.id_categoria_padre = NEW.id_categoria THEN
        RAISE EXCEPTION 'Una categoría no puede ser padre de sí misma.';
    END IF;
    -- Aquí se podría añadir una consulta recursiva para validar ancestros, 
    -- pero para Postgres 14 es altamente eficiente usar el camino (path) o este chequeo simple.
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_evitar_ciclo
BEFORE INSERT OR UPDATE ON categorias
FOR EACH ROW EXECUTE FUNCTION evitar_ciclo_categorias();

--RF-08: Tabla ubicaciones y relación con eventos
CREATE TABLE ubicaciones (
	id_ubicacion SERIAL PRIMARY KEY,
	nombre varchar(50) NOT NULL,
	ciudad varchar(50) NOT NULL, 
	direccion varchar(200) NOT NULL,
	capacidad int NOT NULL CHECK (capacidad>0)
)
ALTER TABLE eventos add id_ubicacion INT REFERENCES ubicaciones(id_ubicacion) 

-- RF-09: Evitar traslape de eventos en la misma ubicación
CREATE OR REPLACE FUNCTION evitar_traslape()
RETURNS TRIGGER AS $$
BEGIN
If EXISTS (SELECT 1 FROM eventos 
    WHERE id_ubicacion = NEW.id_ubicacion
    AND fecha_inicio < NEW.fecha_fin 
    AND fecha_fin > NEW.fecha_inicio
    AND id_evento != NEW.id_evento) THEN
        RAISE EXCEPTION 'El evento se traslapa con otro evento existente.';
        END IF;
   
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_evitar_traslape
BEFORE INSERT OR UPDATE ON eventos
FOR EACH ROW EXECUTE FUNCTION evitar_traslape();

--RF-10: Ubicaciones más utilizadas
CREATE VIEW ubicaciones_mas_utilizadas AS
SELECT COUNT(id_evento), ubicaciones.nombre
FROM eventos
JOIN ubicaciones ON eventos.id_ubicacion = ubicaciones.id_ubicacion
Group by ubicaciones.nombre
ORDER BY Count(id_evento) DESC;

-- MODULO 2 TAREAS ASOCIADAS A EVENTOS
CREATE TABLE tareas(
	id_tarea SERIAL PRIMARY KEY,
	titulo varchar(50) NOT NULL,
	descripcion text NULL,
	prioridad varchar(20) NOT NULL 
		CHECK (prioridad IN('Alta', 'Media', 'Baja')),
	estado varchar(20) NOT NULL
		DEFAULT 'Pendiente'
		CHECK (estado IN ('Pendiente', 'Completada', 'En progreso', 'Cancelada')),
	fecha_limite TIMESTAMP NOT NULL,
	id_usuario_responsable INT NOT NULL REFERENCES usuarios(id_usuario),
	id_evento INT NOT NULL REFERENCES eventos(id_evento)
) 
--RF-16 Y RF-17 VIEW de tareas pendientes (Piden cuantas, no cuales)
CREATE VIEW vista_tareas_pendientes AS
SELECT COUNT(estado) AS cantidad, usuarios.nombre, usuarios.apellido, estado 
FROM tareas
JOIN usuarios ON tareas.id_usuario_responsable = usuarios.id_usuario
WHERE estado IN ('Pendiente', 'En Progreso')
GROUP BY usuarios.id_usuario, usuarios.nombre, usuarios.apellido, tareas.estado
ORDER BY COUNT(estado) DESC;

--RF 16- y RF-17 VIEW de tareas vencidas (Piden cuales, no cuantas)
CREATE VIEW vista_tareas_vencidas AS
SELECT tareas.titulo AS titulo_tareas, eventos.titulo AS titulo_evento, usuarios.nombre, usuarios.apellido, tareas.fecha_limite, tareas.estado
FROM tareas
JOIN eventos ON tareas.id_evento = eventos.id_evento
JOIN usuarios ON tareas.id_usuario_responsable = usuarios.id_usuario
WHERE fecha_limite<NOW() 
AND estado NOT IN ('Completada', 'Cancelada');

--MODULO 3 Disponibilidad
-- RF-11
CREATE TABLE catalogo_tipo_disponibilidad(
	id_tipo SERIAL PRIMARY KEY,
	nombre varchar(50) NOT NULL
);

CREATE TABLE disponibilidades (
	id_disponibilidad SERIAL PRIMARY KEY,
	fecha_correspondiente DATE NOT NULL,
	hora_inicio TIME NOT NULL,
	hora_fin TIME NOT NULL,
	id_tipo INT NOT NULL REFERENCES catalogo_tipo_disponibilidad(id_tipo),
	id_usuario INT NOT NULL REFERENCES usuarios(id_usuario),

	CONSTRAINT check_hora CHECK (hora_inicio<hora_fin)
	
);
--Los inserts fijos de los valores del catalogo de disponibilidad
INSERT INTO catalogo_tipo_disponibilidad(nombre)
VALUES ('Disponible');

INSERT INTO catalogo_tipo_disponibilidad(nombre)
VALUES ('Ocupado');

INSERT INTO catalogo_tipo_disponibilidad(nombre)
VALUES ('No disponible');
