# Mobily — Automatizaciones

Repositorio de scripts y pipelines de automatización para el proyecto **Mobily**. Aquí se publican de forma incremental los scripts que se desarrollan en los distintos entornos (Jenkins, shell, etc.).

## Estructura del repositorio

```
mobily_project/
├── README.md
├── jenkins/
│   └── pipelines/          # Pipelines declarativos de Jenkins
└── scripts/                # Scripts shell, Python, etc. (futuros)
```

| Carpeta | Contenido |
|---------|-----------|
| `jenkins/pipelines/` | Jobs de Jenkins (Groovy, pipeline declarativo) |
| `scripts/` | Scripts independientes (bash, Python, etc.) |

## Scripts incluidos

### Jenkins

| Script | Descripción |
|--------|-------------|
| [`jenkins/pipelines/FileSystemApplicatonBackup.groovy`](jenkins/pipelines/FileSystemApplicatonBackup.groovy) | Pipeline de **backup del filesystem de aplicación** en nodos Jenkins etiquetados por entorno. Valida disponibilidad del nodo, comprueba espacio en disco en todos los nodos del label y ejecuta el backup en paralelo. |

#### FileSystemApplicatonBackup.groovy

Pipeline en tres etapas:

1. **Validar nodo** — Comprueba que exista un agente con el label indicado en `params.Environment` (timeout 20 s).
2. **Validar espacio en disco** — En todos los nodos con ese label, verifica que `ATA_HOME` esté definido y que haya al menos `params.REQUIRED_GB` GB libres; aborta si algún nodo no cumple.
3. **Backup en paralelo** — En cada nodo, genera un `.tar.gz` del árbol de aplicación (excluyendo logs, archivos y releases según reglas del script), copia `.profile` versionado y archiva logs como artefactos de Jenkins.

**Parámetros esperados (ejemplo):**

| Parámetro | Uso |
|-----------|-----|
| `Environment` | Label de Jenkins del entorno (ej. prod, preprod) |
| `REQUIRED_GB` | Espacio mínimo requerido en `ATA_HOME` |

**Variables de entorno en el agente:**

- `ATA_HOME` — Raíz de la instalación a respaldar (obligatoria).
- `ATA_INSTANCE` — Opcional; se registra en los logs.

**Post-acciones:** en éxito, archiva `*.log` de cada nodo; en fallo o aborto, mensajes informativos en la consola.

## Cómo usar un pipeline en Jenkins

1. Crear un job tipo **Pipeline**.
2. En *Pipeline script from SCM* o *Pipeline script*, apuntar al contenido de `jenkins/pipelines/<nombre>.groovy`.
3. Definir los parámetros `Environment` y `REQUIRED_GB` en el job.
4. Asegurar que los agentes tengan `ATA_HOME` (y opcionalmente `ATA_INSTANCE`) configurados.

## Añadir un script nuevo

1. Colocar el archivo en la carpeta que corresponda (`jenkins/pipelines/`, `scripts/`, etc.).
2. Actualizar la tabla **Scripts incluidos** en este README con nombre, ruta y breve descripción.
3. Hacer commit y push a GitHub.

## Requisitos generales

- Acceso a Jenkins con nodos etiquetados por entorno.
- En pipelines de backup: `tar`, `df`, shell compatible con las comprobaciones del script.
- Permisos de lectura en `ATA_HOME` en los agentes.

## Licencia

Uso interno del proyecto Mobily salvo que se indique otra licencia en el repositorio.
