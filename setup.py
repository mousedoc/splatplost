from pathlib import Path

from setuptools import find_packages, setup

this_directory = Path(__file__).parent
long_description = (this_directory / "readme.md").read_text(encoding="utf-8")

setup(
        name='splatplost',
        version='0.2.0',
        packages=find_packages(),
        url='https://github.com/Victrid/splatplost',
        license='GPLv3',
        author='Weihao Jiang',
        author_email='weihau.chiang@gmail.com',
        description='A software-based SplatPost plotter.',
        long_description=long_description,
        long_description_content_type='text/markdown',
        python_requires='>=3.9',
        classifiers=[
            "Development Status :: 3 - Alpha",
            "Operating System :: Microsoft :: Windows",
            "Operating System :: POSIX :: Linux",
            "Programming Language :: Python :: 3",
            ],
        install_requires=[
            "numpy>=1.23,<3",
            "Pillow>=9.2,<13",
            "tqdm>=4.64,<5",
            "libnxctrl>=0.2.1,<0.3",
            "pyserial>=3.5,<4",
            "tsp-solver2>=0.4.1,<0.5",
            ],
        extras_require={
            "bluetooth": [
                "libnxctrl[nxbt]>=0.2.1,<0.3; platform_system == 'Linux'",
                ],
            "build": ["pyinstaller>=6.0,<7"],
            },
        entry_points={
            "console_scripts": [
                "splatplan=splatplost.cli_plan:main",
                "splatplot=splatplost.cli_plot:main",
                ],
            },
        )
